// 玩家包只读取已验证的兼容性覆盖；旧诊断文件不能重新开启采样、丢绘制或候选路径。
// Player packages accept only verified compatibility overrides; old diagnostic files cannot enable sampling, dropped draws or candidate paths.
#ifndef P5R_PLAYER_CONFIG_H
#define P5R_PLAYER_CONFIG_H
#include <string.h>
static inline int p5r_player_config_allowed(const char *key,const char *value) {
    return key && value &&
        ((!strcmp(key,"DM_P5R_NO_DEPTHBOUNDS") && !strcmp(value,"1")) ||
         (!strcmp(key,"DM_P5R_SKIP_DEPTH_DRAW") && !strcmp(value,"0")) ||
         (!strcmp(key,"DM_P5R_COND_IGNORE") && !strcmp(value,"1")));
}
#endif
