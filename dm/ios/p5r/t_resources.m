// 合成目录验证资源选择契约：版本、缺失文件、损坏头、目录越界及旧文稿兼容；不包含游戏内容。
// Synthetic directories verify the resource-selection contract: versions, missing files, corrupt headers, directory escapes and legacy Documents compatibility; no game content.
#import "resources.h"
#include <assert.h>
#include <stdio.h>

static void writeFile(NSURL *root,NSString *path,NSData *data) {
    NSURL *url=[root URLByAppendingPathComponent:path];
    assert([NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([data writeToURL:url atomically:YES]);
}
static void stringFile(NSURL *root,NSString *path,NSString *value) {writeFile(root,path,[value dataUsingEncoding:NSUTF8StringEncoding]);}
static void manifestFile(NSURL *root,NSDictionary *manifest) {
    writeFile(root,@"p5r-resources.json",[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil]);
}
int main(void) { @autoreleasepool {
    NSFileManager *fm=NSFileManager.defaultManager;int cases=0;
    for(int test=0;test<12;test++) { @autoreleasepool {
        NSURL *parent=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSURL *root=[parent URLByAppendingPathComponent:@"resources" isDirectory:YES];
        NSString *chain=@"0123456789ab",*key=@"0123456789abcdef";
        NSString *lib=[NSString stringWithFormat:@"p5r-shaders/b-%@/%@_b.metallib",chain,key];
        NSString *reflection=[NSString stringWithFormat:@"p5r-shaders/b-%@/%@_b.json",chain,key];
        stringFile(root,@"romfs/CPK/ALL_ASIA.CPK",@"CPK synthetic");
        stringFile(root,@"romfs/CPK/PATCH1.CPK",@"CPK patch");
        stringFile(root,@"dm/shader_map.tsv",[NSString stringWithFormat:@"package\tindex\tstage\tcontrol_key\np5r\t0\tvs\t%@\n",key]);
        stringFile(root,@"dm/c1_full.tsv",[@"# chain b-" stringByAppendingString:chain]);
        stringFile(root,lib,@"MTLBsynthetic");
        writeFile(root,reflection,[NSJSONSerialization dataWithJSONObject:@{@"profile":@"p5r",@"chain":chain} options:0 error:nil]);
        NSMutableDictionary *required=[NSMutableDictionary dictionary];
        for(NSString *name in @[@"romfs/CPK/ALL_ASIA.CPK",@"romfs/CPK/PATCH1.CPK",@"dm/shader_map.tsv",@"dm/c1_full.tsv"])
            required[name]=[fm attributesOfItemAtPath:[root.path stringByAppendingPathComponent:name] error:nil][NSFileSize];
        NSMutableDictionary *manifest=[@{@"schema_version":@1,@"profile":@"p5r",@"shader_chain":chain,@"guest_sha256":@"synthetic",@"shader_count":@1,@"required_files":required} mutableCopy];
        manifestFile(root,manifest);
        if(test==1){manifest[@"shader_chain"]=@"other";manifestFile(root,manifest);}
        if(test==2){manifest[@"guest_sha256"]=@"other";manifestFile(root,manifest);}
        if(test==3)assert([fm removeItemAtURL:[root URLByAppendingPathComponent:@"romfs/CPK/PATCH1.CPK"] error:nil]);
        if(test==4)assert([fm removeItemAtURL:[root URLByAppendingPathComponent:lib] error:nil]);
        if(test==5)stringFile(root,lib,@"BAD!synthetic");
        if(test==6){required[@"../outside"]=@0;manifestFile(root,manifest);}
        if(test==7)stringFile(root,@"dm/c1_full.tsv",@"# chain b-other");
        if(test==8){
            NSURL *target=[parent URLByAppendingPathComponent:@"outside"];
            stringFile(parent,@"outside",@"CPK synthetic");
            NSURL *link=[root URLByAppendingPathComponent:@"romfs/CPK/ALL_ASIA.CPK"];
            assert([fm removeItemAtURL:link error:nil]);assert([fm createSymbolicLinkAtURL:link withDestinationURL:target error:nil]);
        }
        if(test==9)stringFile(root,reflection,@"{\"profile\":\"other\",\"chain\":\"0123456789ab\"}");
        if(test>=10)assert([fm removeItemAtURL:[root URLByAppendingPathComponent:@"p5r-resources.json"] error:nil]);
        NSString *error=nil;
        NSDictionary *result=p5r_resources(root,chain,@"synthetic",[root URLByAppendingPathComponent:@"dm"],test==11,&error);
        BOOL valid=test==0 || test==11;
        assert((result!=nil)==valid);assert((error==nil)==valid);
        if(valid)assert([result[@"romfs"].path isEqual:[root.path stringByAppendingPathComponent:@"romfs"]]);
        assert([fm removeItemAtURL:parent error:nil]);cases++;
    }}
    printf("P5R_RESOURCES: %d synthetic cases passed\n",cases);return 0;
}}
