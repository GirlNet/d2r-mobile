// Real builder/query thunks: independent linear-render-target flag must not enter tiled layout.
static void test_texture_linear(void) {
    NVNtextureBuilder b={0};P(nvnTextureBuilderSetDevice)(&b,&dev);P(nvnTextureBuilderSetDefaults)(&b);
    P(nvnTextureBuilderSetSize2D)(&b,16,16);P(nvnTextureBuilderSetFormat)(&b,NVN_FORMAT_RGBA8);P(nvnTextureBuilderSetStride)(&b,128);
    const int flags[]={0x10,0x14,0x40,0x44,0x50,0x54};
    for(unsigned i=0;i<sizeof flags/sizeof *flags;i++) {
        P(nvnTextureBuilderSetFlags)(&b,flags[i]);
        EXPECT("linear flags keep explicit row stride",2048,P(nvnTextureBuilderGetStorageSize)(&b));
        EXPECT("linear alignment distinguishes render targets",flags[i]&0x40 ? 128 : 32,P(nvnTextureBuilderGetStorageAlignment)(&b));
    }
    P(nvnTextureBuilderSetFlags)(&b,NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET|NVN_TEXTURE_FLAGS_IMAGE);
    NVNtexture t;EXPECT("linear render-target object initializes",1,P(nvnTextureInitialize)(&t,&b));
    EXPECT("linear render-target retained object size",2048,P(nvnTextureGetStorageSize)(&t));
    EXPECT("linear render-target retained stride",128,P(nvnTextureGetStride)(&t));
    P(nvnTextureFinalize)(&t);
    P(nvnTextureBuilderSetFlags)(&b,0);P(nvnTextureBuilderSetStride)(&b,0);
    EXPECT("ordinary tiled size unchanged",1024,P(nvnTextureBuilderGetStorageSize)(&b));
    EXPECT("ordinary tiled alignment unchanged",512,P(nvnTextureBuilderGetStorageAlignment)(&b));
}
