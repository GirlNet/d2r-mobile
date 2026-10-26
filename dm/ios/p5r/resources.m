// 基于已选目录和本地包清单解析 P5R 只读资源；路径、版本和完整性失败均返回本地化键。
// Resolve read-only P5R resources from the selected directory and local manifest; path, version and completeness failures return localization keys.
#import "resources.h"
#include <string.h>

static NSURL *child(NSURL *root, NSString *name) {
    if(!root || !name.length || [name hasPrefix:@"/"])return nil;
    for(NSString *part in name.pathComponents)if([part isEqual:@".."] || [part isEqual:@"."])return nil;
    NSURL *url=[[root URLByAppendingPathComponent:name] URLByResolvingSymlinksInPath];
    NSString *prefix=[root.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    return [url.path hasPrefix:prefix]?url:nil;
}
static BOOL regular(NSURL *url) {
    NSNumber *value=nil;return url && [url getResourceValue:&value forKey:NSURLIsRegularFileKey error:nil] && value.boolValue;
}
static BOOL magic(NSURL *url,const char *expected) {
    if(!url)return NO;
    NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:url error:nil];if(!file)return NO;
    NSData *data=[file readDataUpToLength:4 error:nil];[file closeFile];
    return data.length==4 && !memcmp(data.bytes,expected,4);
}
NSDictionary<NSString *,NSURL *> *p5r_resources(NSURL *root,NSString *chain,NSString *guestHash,
    NSURL *legacyDM,BOOL allowLegacy,NSString **errorKey) {
    if(errorKey)*errorKey=@"dmP5RResourcesIncomplete";
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *manifestURL=child(root,@"p5r-resources.json");
    NSData *manifestData=manifestURL?[NSData dataWithContentsOfURL:manifestURL]:nil;
    NSDictionary *manifest=manifestData?[NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil]:nil;
    if(manifestData && ![manifest isKindOfClass:NSDictionary.class])return nil;
    if(!manifest && !allowLegacy){if(errorKey)*errorKey=@"dmP5RResourcesChooseHint";return nil;}
    if(manifest && (!([manifest[@"schema_version"] isEqual:@1]) || ![manifest[@"profile"] isEqual:@"p5r"] ||
        ![manifest[@"shader_chain"] isEqual:chain] || ![manifest[@"guest_sha256"] isEqual:guestHash])) {
        if(errorKey)*errorKey=@"dmP5RResourcesVersion";return nil;
    }
    NSURL *romfs=child(root,@"romfs"),*shaders=child(root,@"p5r-shaders"),*dm=child(root,@"dm");
    if(!regular(child(dm,@"shader_map.tsv")) && allowLegacy)dm=legacyDM;
    NSURL *map=child(dm,@"shader_map.tsv"),*constants=child(dm,@"c1_full.tsv");
    NSURL *all=child(romfs,@"CPK/ALL_ASIA.CPK");
    if(!regular(all) || !magic(all,"CPK ") || !regular(map) || !regular(constants))return nil;
    if(manifest) {
        NSDictionary *required=manifest[@"required_files"];
        if(![required isKindOfClass:NSDictionary.class] || required.count<3 || required.count>128)return nil;
        if(!required[@"romfs/CPK/ALL_ASIA.CPK"] || !required[@"dm/shader_map.tsv"] || !required[@"dm/c1_full.tsv"])return nil;
        for(id name in required) {
            if(![name isKindOfClass:NSString.class] || ![required[name] isKindOfClass:NSNumber.class])return nil;
            NSURL *url=child(root,name);NSNumber *size=nil;
            if(!regular(url) || ![url getResourceValue:&size forKey:NSURLFileSizeKey error:nil] || ![size isEqual:required[name]])return nil;
        }
    }
    NSString *chainDirectory=[@"b-" stringByAppendingString:chain];NSURL *libraries=child(shaders,chainDirectory);
    if(!libraries)return nil;
    NSArray<NSString *> *names=[fm contentsOfDirectoryAtPath:libraries.path error:nil];if(!names)return nil;
    NSSet *available=[NSSet setWithArray:names];NSMutableSet *keys=[NSMutableSet set];
    NSString *table=[NSString stringWithContentsOfURL:map encoding:NSUTF8StringEncoding error:nil];
    NSString *full=[NSString stringWithContentsOfURL:constants encoding:NSUTF8StringEncoding error:nil];
    if(![full hasPrefix:[@"# chain " stringByAppendingString:chainDirectory]])return nil;
    NSCharacterSet *nonHex=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    for(NSString *line in [table componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if(!line.length || [line hasPrefix:@"#"] || [line hasPrefix:@"package\t"])continue;
        NSArray *fields=[line componentsSeparatedByString:@"\t"];if(fields.count!=4 || ![fields[0] isEqual:@"p5r"])return nil;
        NSString *key=fields[3];if(key.length!=16 || [key rangeOfCharacterFromSet:nonHex].location!=NSNotFound)return nil;
        if([keys containsObject:key])return nil;[keys addObject:key];
        if(![available containsObject:[key stringByAppendingString:@"_b.metallib"]] || ![available containsObject:[key stringByAppendingString:@"_b.json"]])return nil;
    }
    if(!keys.count || (manifest && ![manifest[@"shader_count"] isEqual:@(keys.count)]))return nil;
    NSString *first=[[keys allObjects] sortedArrayUsingSelector:@selector(compare:)].firstObject;
    if(!magic(child(libraries,[first stringByAppendingString:@"_b.metallib"]),"MTLB"))return nil;
    NSData *reflectionData=[NSData dataWithContentsOfURL:child(libraries,[first stringByAppendingString:@"_b.json"])];
    NSDictionary *reflection=reflectionData?[NSJSONSerialization JSONObjectWithData:reflectionData options:0 error:nil]:nil;
    if(![reflection isKindOfClass:NSDictionary.class] || ![reflection[@"profile"] isEqual:@"p5r"] || ![reflection[@"chain"] isEqual:chain])return nil;
    if(errorKey)*errorKey=nil;
    return @{@"root":root,@"romfs":romfs,@"shaders":shaders,@"map":map};
}
