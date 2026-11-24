#ifndef DDC_H
#define DDC_H

// 薄封装：基于 m1ddc 的 DDC/CI 传输层（MIT，见 M1DDC-LICENSE.txt）。
// 供 Swift 调用：枚举显示器、读写 VCP 0x60 输入源、读 0xF3 能力字符串。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DDC : NSObject

// 枚举所有外部 DCPAVServiceProxy（包括正在显示别的输入源的显示器）。
// 返回字典数组（productName/manufacturer/alphaSerial/registryID/vendor/model/serial/driven）。
// 不返回自定义对象，避免对象生命周期问题。
+ (NSArray<NSDictionary *> *)listDisplays;

// 以下以 registryID 指定显示器。

// 读取 VCP feature。outCur/outMax 可为 NULL。成功返回 YES。
+ (BOOL)getVCP:(UInt8)code registryID:(UInt64)rid cur:(nullable UInt16 *)outCur max:(nullable UInt16 *)outMax;

// 写 VCP feature。成功返回 YES（仅表示写入成功）。
+ (BOOL)setVCP:(UInt8)code registryID:(UInt64)rid value:(UInt16)value;

// 读取显示器能力字符串（VCP 0xF3）。拿不到返回 nil。
+ (nullable NSString *)capabilitiesString:(UInt64)rid;

@end

NS_ASSUME_NONNULL_END

#endif
