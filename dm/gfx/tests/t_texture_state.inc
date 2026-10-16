// Typed production APIs, inherited/overridden sampling state and reserved-size guards.
static void test_texture_state(void) {
    struct { uint64_t before; NVNtextureView v; uint64_t after; } gv={.before=17,.after=23};
    struct { uint64_t before; NVNtextureBuilder b; uint64_t after; } gb={.before=29,.after=31};
    struct { uint64_t before; NVNtexture t; uint64_t after; } gt={.before=37,.after=41};
    NVNtextureView *v=&gv.v;NVNtextureBuilder *b=&gb.b;NVNtexture *t=&gt.t;
    NVNtextureSwizzle c[4]={9,9,9,9};NVNtextureDepthStencilMode mode=(NVNtextureDepthStencilMode)9;
    P(nvnTextureViewSetDefaults)(v);
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
