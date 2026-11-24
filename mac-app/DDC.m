#import "DDC.h"

#include "avservice.h"
#include "i2c.h"
#include "ioregistry.h"
#include <unistd.h>

// ---------- 内部 ----------

static BOOL openTransport(UInt64 rid, DDCTransport *out) {
    AVServiceInfos infos[MAX_AVSERVICES];
    int n = getAVServiceInfos(infos, MAX_AVSERVICES);
    BOOL ok = NO;
    for (int i = 0; i < n; i++) {
        if (infos[i].registryID == rid) {
            *out = getAVServiceDDCTransport(&infos[i]);
            ok = out->service != NULL;
        }
    }
    releaseAVServiceInfos(infos, n);
    return ok;
}

static void closeTransport(DDCTransport *t) {
    if (t->service) { CFRelease(t->service); t->service = NULL; }
}

@implementation DDC

+ (NSArray<NSDictionary *> *)listDisplays {
    DisplayInfos displays[MAX_DISPLAYS];
    CGDisplayCount displayCount = getOnlineDisplayInfos(displays);
    AVServiceInfos infos[MAX_AVSERVICES];
    int n = getAVServiceInfos(infos, MAX_AVSERVICES);
    matchAVServicesToDisplays(infos, n, displays, displayCount);

    NSMutableArray *out = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        if (infos[i].edidStatus != kIOReturnSuccess) continue; // 读不出 EDID 的忽略
        [out addObject:@{
            @"productName":  infos[i].productName ? [NSString stringWithString:infos[i].productName] : @"未知显示器",
            @"manufacturer": infos[i].manufacturer ? [NSString stringWithString:infos[i].manufacturer] : @"",
            @"alphaSerial":  infos[i].alphNumSerial ? [NSString stringWithString:infos[i].alphNumSerial] : @"",
            @"registryID":   @(infos[i].registryID),
            @"vendor":       @(infos[i].vendor),
            @"model":        @(infos[i].model),
            @"serial":       @(infos[i].serial),
            @"driven":       @(infos[i].displayID != 0),
        }];
    }
    releaseAVServiceInfos(infos, n);
    return out;
}

+ (BOOL)getVCP:(UInt8)code registryID:(UInt64)rid cur:(UInt16 *)outCur max:(UInt16 *)outMax {
    DDCTransport t;
    if (!openTransport(rid, &t)) return NO;
    BOOL ok = NO;
    for (int i = 0; i < 4 && !ok; i++) {
        DDCPacket p = createDDCPacket(code);
        prepareDDCRead(&p);
        if (performDDCWriteAtChipAddress(t.service, t.chipAddress, &p) != kIOReturnSuccess) break;
        if (performDDCReadAtChipAddress(t.service, t.chipAddress, &p) != kIOReturnSuccess) break;
        DDCReplyStatus st = checkDDCReply(p.data, code);
        if (st == DDC_REPLY_UNSUPPORTED) break;
        if (st == DDC_REPLY_OK) {
            DDCValue v = convertI2CtoDDC((char *)p.data);
            if (outCur) *outCur = (UInt16)v.curValue;
            if (outMax) *outMax = (UInt16)v.maxValue;
            ok = YES;
        }
        usleep(DDC_RETRY_WAIT);
    }
    closeTransport(&t);
    return ok;
}

+ (BOOL)setVCP:(UInt8)code registryID:(UInt64)rid value:(UInt16)value {
    DDCTransport t;
    if (!openTransport(rid, &t)) return NO;
    DDCPacket p = createDDCPacket(code);
    prepareDDCWrite(&p, value);
    IOReturn r = performDDCWriteAtChipAddress(t.service, t.chipAddress, &p);
    closeTransport(&t);
    return r == kIOReturnSuccess;
}

// VCP 0xF3 Capabilities：请求 [0x82, 0x02, 0xF3, offsetHi, offsetLo, chk]，
// 回复 [0x6E, 0x80|len, 0xE3, 0xF3, offHi, offLo, data(len-3)..., chk]。
+ (NSString *)capabilitiesString:(UInt64)rid {
    DDCTransport t;
    if (!openTransport(rid, &t)) return nil;
    NSMutableData *caps = [NSMutableData data];
    UInt16 offset = 0;
    BOOL ok = NO;
    for (int frag = 0; frag < 24; frag++) {
        UInt8 req[6] = {0x82, 0x02, 0xF3, (UInt8)(offset >> 8), (UInt8)(offset & 0xFF), 0};
        UInt8 chk = 0x6E ^ DEFAULT_INPUT_ADDRESS;
        for (int i = 0; i < 5; i++) chk ^= req[i];
        req[5] = chk;
        if (IOAVServiceWriteI2C(t.service, t.chipAddress, DEFAULT_INPUT_ADDRESS, req, 6) != kIOReturnSuccess) break;
        usleep(60000);
        UInt8 buf[64];
        memset(buf, 0, sizeof(buf));
        IOReturn rr = IOAVServiceReadI2C(t.service, t.chipAddress, DEFAULT_INPUT_ADDRESS, buf, 50);
        if (getenv("DDC_DEBUG")) {
            NSMutableString *h = [NSMutableString string];
            for (int i = 0; i < 24; i++) [h appendFormat:@"%02X ", buf[i]];
            NSLog(@"[caps rd] ret=%08x buf=%@", rr, h);
        }
        if (rr != kIOReturnSuccess) break;
        // 常见合法回复头：[6E 88 E3 F3]（len=8）或 [6E 87 E3 F3]；也接受 E3 后带偏移的变体。
        if (buf[0] != 0x6E || buf[2] != 0xE3) break;
        int len = buf[1] & 0x7F;
        if (getenv("DDC_DEBUG")) {
            NSMutableString *h = [NSMutableString string];
            for (int i = 0; i < 24; i++) [h appendFormat:@"%02X ", buf[i]];
            NSLog(@"[caps frag] %@ (len=%d)", h, len);
        }
        if (len < 3 || 3 + (len - 3) + 3 > 50) break;
        // 校验 checksum：0x50 XOR 前 (3+len) 个字节
        UInt8 sum = 0x50;
        int hdr = 3 + len;
        for (int i = 0; i < hdr; i++) sum ^= buf[i];
        if (sum != buf[hdr]) break;
        int dataStart = (buf[3] == 0xF3) ? 6 : 3;
        [caps appendBytes:&buf[dataStart] length:len - (dataStart - 3)];
        offset += len - (dataStart - 3);
        ok = YES;
        if ((buf[1] & 0x80) == 0) break; // 最后一帧
    }
    closeTransport(&t);
    return ok ? [[NSString alloc] initWithData:caps encoding:NSASCIIStringEncoding] : nil;
}

@end
