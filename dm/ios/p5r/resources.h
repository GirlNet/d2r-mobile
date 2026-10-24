// P5R 文件夹资源验证：检查本地包身份、必要数据与着色器映射，不加载或修改游戏文件。
// P5R folder resource validation: check local package identity, required data and shader mappings without loading or modifying game files.
#import <Foundation/Foundation.h>

NSDictionary<NSString *,NSURL *> *p5r_resources(NSURL *root, NSString *chain, NSString *guestHash,
    NSURL *legacyDM, BOOL allowLegacy, NSString **errorKey);
