// Portable resource checks also run on development hosts without a Metal device.
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "../nvn/nvn_resource_contract.h"
#define CHECK(x) do{if(!(x)){fprintf(stderr,"resource contract check failed at %d\n",__LINE__);return 1;}}while(0)
#define ERROR(message,...) do{const char *error=nvn_texture_contract_error(__VA_ARGS__);CHECK(error && !strcmp(error,message));}while(0)
int main(void) {
    unsigned cases=0;
    for(unsigned dimension=0;dimension<=9;dimension++) {
        for(unsigned expected=0;expected<4;expected++)for(unsigned actual=0;actual<4;actual++) {
            nvn_rbind b={.kind=NVN_RB_TEX,.dtt=dimension,.dpf=expected};
            unsigned samples=dimension==4||dimension==8?4:1;
            const char *error=nvn_texture_contract_error(&b,1,dimension,actual,actual==NVN_DPF_DEPTH,samples,1,0);
            CHECK((error==NULL)==(expected==actual));cases++;
        }
    }
    nvn_rbind b={.kind=NVN_RB_TEX,.dtt=2,.dpf=NVN_DPF_FLOAT};
    CHECK(!nvn_texture_contract_error(&b,1,2,NVN_DPF_FLOAT,1,1,1,0)); // ordinary depth read
    ERROR("missing texture descriptor",&b,0,2,0,0,1,1,0);
    ERROR("texture dimension mismatch",&b,1,5,0,0,1,1,0);
    ERROR("texture sample count mismatch",&b,1,2,0,0,4,1,0);
    ERROR("texture sample count mismatch",&b,1,2,0,0,0,1,0);
    ERROR("texture lacks shader read usage",&b,1,2,0,0,1,0,0);
    b.kind=NVN_RB_IMG;
    ERROR("image lacks shader write usage",&b,1,2,0,0,1,1,0);
    CHECK(!nvn_texture_contract_error(&b,1,2,0,0,1,1,1));
    b.kind=NVN_RB_TBUF;
    CHECK(!nvn_texture_contract_error(&b,1,9,0,0,1,1,0));
    ERROR("texture dimension mismatch",&b,1,2,0,0,1,1,0);
    b.kind=NVN_RB_TEX;b.dtt=4;
    ERROR("texture sample count mismatch",&b,1,4,0,0,1,1,0);
    CHECK(!nvn_texture_contract_error(&b,1,4,0,0,4,1,0));
    b.dtt=2;b.dpf=NVN_DPF_DEPTH;
    ERROR("comparison texture requires depth format",&b,1,2,0,0,1,1,0);
    printf("RESOURCE CONTRACT OK: %u dimension/numeric combinations and missing/usage/sample/buffer/depth boundaries\n",cases);
    return 0;
}
