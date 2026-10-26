// Typed production APIs, inherited/overridden sampling state and reserved-size guards.
static void test_texture_state(void) {
    // Match the guest's 16-byte view followed immediately by its copy region.
    // A larger host view used to erase width/height before recording the copy.
    struct { uint64_t before; NVNtextureView v; NVNcopyRegion region; uint64_t after; } adjacent={
        .before=17,.region={0,0,0,256,1,1},.after=23};
    const NVNcopyRegion expected_region={0,0,0,256,1,1};
    const uint8_t zero_view[16]={0};
    EXPECT("view occupies guest's 16-byte stack slot",16,sizeof adjacent.v);
    P(nvnTextureViewSetDefaults)(&adjacent.v);
    EXPECT("view defaults initialize all 16 bytes",0,memcmp(&adjacent.v,zero_view,16));
    EXPECT("view defaults preserve adjacent copy extent",0,memcmp(&adjacent.region,&expected_region,sizeof expected_region));
    P(nvnTextureViewSetLevels)(&adjacent.v,0x1ab,0x2cd);
    P(nvnTextureViewSetLayers)(&adjacent.v,0x1234,0x5678);
    P(nvnTextureViewSetTarget)(&adjacent.v,NVN_TEXTURE_TARGET_3D);
    P(nvnTextureViewSetFormat)(&adjacent.v,NVN_FORMAT_BGRA8);
    P(nvnTextureViewSetSwizzle)(&adjacent.v,2,3,4,5);
    P(nvnTextureViewSetDepthStencilMode)(&adjacent.v,(NVNtextureDepthStencilMode)5);
    const uint8_t expected_view[16]={0x34,0x12,0x78,0x56,0xab,0xcd,2,0x7f,0x9a,0,0,0,2,3,4,5};
    EXPECT("view raw ABI matches independent SDK words",0,memcmp(&adjacent.v,expected_view,16));
    EXPECT("all view setters preserve adjacent region",0,memcmp(&adjacent.region,&expected_region,sizeof expected_region));
    EXPECT("compact view guard words",1,adjacent.before==17 && adjacent.after==23);
    int base=-1,count=-1;
    EXPECT("view levels getter valid",1,P(nvnTextureViewGetLevels)(&adjacent.v,&base,&count));
    EXPECT("view levels retain byte values",1,base==0xab && count==0xcd);
    EXPECT("view layers getter valid",1,P(nvnTextureViewGetLayers)(&adjacent.v,&base,&count));
    EXPECT("view layers retain 16-bit values",1,base==0x1234 && count==0x5678);
    struct { uint64_t before; NVNtextureView v; uint64_t after; } gv={.before=17,.after=23};
    struct { uint64_t before; NVNtextureBuilder b; uint64_t after; } gb={.before=29,.after=31};
    struct { uint64_t before; NVNtexture t; uint64_t after; } gt={.before=37,.after=41};
    NVNtextureView *v=&gv.v;NVNtextureBuilder *b=&gb.b;NVNtexture *t=&gt.t;
    NVNtextureSwizzle c[4]={9,9,9,9};NVNtextureDepthStencilMode mode=(NVNtextureDepthStencilMode)9;
    P(nvnTextureViewSetDefaults)(v);
    struct { uint32_t before;int base,count;uint32_t after; } levels={17,99,99,23};
    EXPECT("unset levels validity",0,P(nvnTextureViewGetLevels)(v,&levels.base,&levels.count));
    EXPECT("unset levels write exact default words",1,levels.base==0 && levels.count==0 && levels.before==17 && levels.after==23);
    levels.base=levels.count=99;
    EXPECT("unset layers validity",0,P(nvnTextureViewGetLayers)(v,&levels.base,&levels.count));
    EXPECT("unset layers write exact default words",1,levels.base==0 && levels.count==0 && levels.before==17 && levels.after==23);
    struct { uint32_t before;NVNformat value;uint32_t after; } fmt={29,(NVNformat)99,31};
    struct { uint32_t before;NVNtextureTarget value;uint32_t after; } target={37,(NVNtextureTarget)99,41};
    EXPECT("unset format validity",0,P(nvnTextureViewGetFormat)(v,&fmt.value));
    EXPECT("unset format writes exact default word",1,fmt.value==0 && fmt.before==29 && fmt.after==31);
    EXPECT("unset target validity",0,P(nvnTextureViewGetTarget)(v,&target.value));
    EXPECT("unset target writes exact default word",1,target.value==0 && target.before==37 && target.after==41);
    EXPECT("unset swizzle validity",0,P(nvnTextureViewGetSwizzle)(v,c,c+1,c+2,c+3));
    EXPECT("unset swizzle writes SDK default words",0,c[0]|c[1]|c[2]|c[3]);
    EXPECT("unset aspect validity",0,P(nvnTextureViewGetDepthStencilMode)(v,&mode));
    EXPECT("unset aspect writes SDK default",0,mode);
    P(nvnTextureBuilderSetDevice)(b,&dev);P(nvnTextureBuilderSetDefaults)(b);P(nvnTextureBuilderSetFormat)(b,NVN_FORMAT_RGBA8);
    P(nvnTextureBuilderGetSwizzle)(b,c,c+1,c+2,c+3);
    EXPECT("builder default identity",1,c[0]==2 && c[1]==3 && c[2]==4 && c[3]==5);
    EXPECT("builder default depth aspect",0,P(nvnTextureBuilderGetDepthStencilMode)(b));
    P(nvnTextureBuilderSetSwizzle)(b,NVN_TEXTURE_SWIZZLE_B,NVN_TEXTURE_SWIZZLE_G,NVN_TEXTURE_SWIZZLE_R,NVN_TEXTURE_SWIZZLE_ONE);
    P(nvnTextureBuilderSetDepthStencilMode)(b,NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL);
    EXPECT("texture state initialize",1,P(nvnTextureInitialize)(t,b));
    P(nvnTextureGetSwizzle)(t,c,c+1,c+2,c+3);
    EXPECT("object retains builder swizzle",1,c[0]==4 && c[1]==3 && c[2]==2 && c[3]==1);
    EXPECT("object retains builder aspect",1,P(nvnTextureGetDepthStencilMode)(t));
    P(nvnTextureBuilderSetDefaults)(b);P(nvnTextureBuilderSetFormat)(b,NVN_FORMAT_RGBA8);
    NVNtexture other;P(nvnTextureInitialize)(&other,b);
    EXPECT("texture comparison includes sampling state",0,P(nvnTextureCompare)(t,&other));
    EXPECT("builder defaults preserve device",(uintptr_t)&dev,(uintptr_t)P(nvnTextureBuilderGetDevice)(b));
    unsigned bad=0;
    for (int r=0;r<6;r++)for(int g=0;g<6;g++)for(int bl=0;bl<6;bl++)for(int a=0;a<6;a++) {
        P(nvnTextureViewSetSwizzle)(v,r,g,bl,a);
        bad+=P(nvnTextureViewGetSwizzle)(v,c,c+1,c+2,c+3)!=1 || c[0]!=r || c[1]!=g || c[2]!=bl || c[3]!=a;
        uint32_t pf;uint8_t swz[4];int aspect;
        bad+=!nvn_texture_sampling_plan((tex_t *)t,(view_t *)v,NVN_FORMAT_RGBA8,&pf,swz,&aspect) ||
             swz[0]!=r || swz[1]!=g || swz[2]!=bl || swz[3]!=a;
    }
    EXPECT("1296 view combinations override builder",0,bad);
    P(nvnTextureViewSetSwizzle)(v,0x102,0x103,0x104,0x105);P(nvnTextureViewGetSwizzle)(v,c,c+1,c+2,c+3);
    EXPECT("view byte storage ABI",1,c[0]==2 && c[1]==3 && c[2]==4 && c[3]==5);
    P(nvnTextureViewSetDepthStencilMode)(v,(NVNtextureDepthStencilMode)5);
    EXPECT("view aspect validity",1,P(nvnTextureViewGetDepthStencilMode)(v,&mode));
    EXPECT("view aspect two-bit storage ABI",1,mode);
    P(nvnTextureBuilderSetSwizzle)(b,(NVNtextureSwizzle)0x102,3,4,5);P(nvnTextureBuilderGetSwizzle)(b,c,c+1,c+2,c+3);
    EXPECT("builder full enum storage ABI",0x102,c[0]);
    P(nvnTextureBuilderSetDepthStencilMode)(b,(NVNtextureDepthStencilMode)5);
    EXPECT("builder full aspect enum ABI",5,P(nvnTextureBuilderGetDepthStencilMode)(b));
    EXPECT("texture state guard bytes",1,gv.before==17 && gv.after==23 && gb.before==29 && gb.after==31 && gt.before==37 && gt.after==41);
    tex_t sample={0};uint32_t pf;uint8_t swz[4];int aspect;
    EXPECT("implicit identity sampling plan",1,nvn_texture_sampling_plan(&sample,NULL,NVN_FORMAT_RGBA8,&pf,swz,&aspect) && swz[0]==2 && swz[3]==5);
    view_t override={.set_swizzle=1,.swizzle={5,2,0,1}};
    EXPECT("format mapping composes with view swizzle",1,nvn_texture_sampling_plan(&sample,&override,NVN_FORMAT_RGBX8,&pf,swz,&aspect) && swz[0]==1 && swz[1]==2 && swz[2]==0 && swz[3]==1);
    override.swizzle[0]=6;
    EXPECT("invalid sampling plan rejected",0,nvn_texture_sampling_plan(&sample,&override,NVN_FORMAT_RGBA8,&pf,swz,&aspect));
    P(nvnTextureFinalize)(t);P(nvnTextureFinalize)(&other);
}
