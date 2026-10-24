// 用合成 ELF 符号/重定位直接验证装载器与 HLE 解析：弱缺省取零，已有定义优先，强缺省仍给桩；不读取游戏。
// Synthetic ELF symbols/relocations exercise the real loader and HLE resolver: missing weak imports are zero, definitions win, and missing strong imports keep stubs; no game files.
#include "../loader.c"
#include <assert.h>

struct dm_flags g_flag;
uint64_t unimpl_stubs[4096];
void *hlecount_wrap(const char *kind, const char *name, void *fn) { (void)kind; (void)name; return fn; }
HLE("synthetic_host", uint64_t, synthetic_host, void) { return 42; }
HLE_FORCE_OPTIONAL("synthetic_cache_flush", "Synthetic platform cache takeover", void, synthetic_cache_flush, const void *address, size_t size) { (void)address; (void)size; }

static uint64_t relocated(unsigned binding, unsigned section, unsigned type, int64_t addend, const char *name) {
    static uint8_t image[4096];
    static Elf64_Sym symbol[2];
    static Elf64_Dyn dynamic[3];
    memset(image,0,sizeof image); memset(symbol,0,sizeof symbol); memset(dynamic,0,sizeof dynamic);
    symbol[1] = (Elf64_Sym){.st_info=(uint8_t)(binding<<4|2),.st_shndx=(uint16_t)section,.st_value=section?0x300:0};
    Elf64_Rela relocation = {.r_offset=0x100,.r_info=(UINT64_C(1)<<32)|type,.r_addend=addend};
    memcpy(image+0x40,&relocation,sizeof relocation);
    dynamic[0] = (Elf64_Dyn){.d_tag=type==R_AARCH64_JUMP_SLOT?DT_JMPREL:DT_RELA,.d_un.d_ptr=0x40};
    dynamic[1] = (Elf64_Dyn){.d_tag=type==R_AARCH64_JUMP_SLOT?DT_PLTRELSZ:DT_RELASZ,.d_un.d_val=sizeof relocation};
    g_mod[0] = (module_t){.base=image,.size=sizeof image,.dyn=dynamic,.symtab=symbol,.nsym=2,.strtab=name};
    relocate(&g_mod[0]);
    uint64_t result; memcpy(&result,image+0x100,sizeof result); return result;
}
int main(void) {
    force_init();
    g_nmod=1;
    const unsigned types[]={R_AARCH64_ABS64,R_AARCH64_GLOB_DAT,R_AARCH64_JUMP_SLOT};
    for (int binding=1;binding<=2;binding++) for (unsigned i=0;i<3;i++) {
        unsigned type=types[i];
        assert(relocated(binding,0,type,0,"synthetic_host")== (uint64_t)synthetic_host);
        assert(relocated(binding,1,type,0,"local_definition")== (uint64_t)g_mod[0].base+0x300);
        assert(relocated(binding,0,type,0,"synthetic_cache_flush")== (uint64_t)synthetic_cache_flush);
        assert(relocated(binding,1,type,0,"synthetic_cache_flush")== (uint64_t)synthetic_cache_flush);
    }
    for (unsigned i=0;i<3;i++) {
        unsigned type=types[i];
        assert(relocated(2,0,type,0,"missing_callback")==0);
        uint64_t strong=relocated(1,0,type,0,"missing_callback");
        assert(strong==(uint64_t)&unimpl_stubs[0]);
        assert(relocated(2,0,type,0,"missing_callback")==0);
        assert(relocated(1,0,type,0,"missing_callback")==strong);
    }
    assert(relocated(2,0,R_AARCH64_ABS64,17,"weak_addend")==17);
    assert(relocated(2,0,R_AARCH64_GLOB_DAT,-7,"weak_addend")==UINT64_MAX-6);
    assert(relocated(2,0,R_AARCH64_JUMP_SLOT,17,"weak_addend")==0);
    static uint8_t other[4096];
    static Elf64_Sym exported[2]={{0},{.st_info=0x12,.st_shndx=1,.st_value=0x200}};
    g_mod[1]=(module_t){.base=other,.size=sizeof other,.symtab=exported,.nsym=2,.strtab="guest_provider"};
    build_symhash(&g_mod[1]); g_nmod=2;
    assert(relocated(2,0,R_AARCH64_GLOB_DAT,0,"guest_provider")== (uint64_t)other+0x200);
    assert(relocated(1,0,R_AARCH64_JUMP_SLOT,0,"guest_provider")== (uint64_t)other+0x200);
    free(g_mod[1].symh);
    free(g_force); free(g_force_hits);
    puts("ELF IMPORTS OK: optional weak callbacks, guest/host definitions, strong stub reuse and relocation addends");
    return 0;
}
