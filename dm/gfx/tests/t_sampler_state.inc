// Real API thunks: raw integer border bits, independent object lifetimes and defaults.
static void test_sampler_state(void) {
    struct { uint64_t before; NVNsamplerBuilder b; uint64_t after; } guarded={.before=0x12345678,.after=0xabcdef};
    NVNsamplerBuilder *b=&guarded.b;
    NVNsampler a={0}, copy={0};
    P(nvnSamplerBuilderSetDevice)(b,&dev);P(nvnSamplerBuilderSetDefaults)(b);
    EXPECT("sampler reduction default",NVN_SAMPLER_REDUCTION_AVERAGE,P(nvnSamplerBuilderGetReductionFilter)(b));
    EXPECT("sampler snap default",1,P(nvnSamplerBuilderGetLodSnap)(b)==0.f);
    for (unsigned mode=0;mode<3;mode++) {
        P(nvnSamplerBuilderSetReductionFilter)(b,(NVNsamplerReduction)mode);
        EXPECT("sampler reduction round trip",mode,P(nvnSamplerBuilderGetReductionFilter)(b));
    }
    P(nvnSamplerBuilderSetReductionFilter)(b,(NVNsamplerReduction)0x101);
    EXPECT("SDK four-bit reduction field",1,P(nvnSamplerBuilderGetReductionFilter)(b));
    P(nvnSamplerBuilderSetLodSnap)(b,-1.25f);
    EXPECT("sampler snap float ABI",1,P(nvnSamplerBuilderGetLodSnap)(b)==-1.25f);
    const int signed_color[4]={INT32_MIN,-1,0,INT32_MAX};int got_i[4];uint32_t got_u[4];float got_f[4];
    P(nvnSamplerBuilderSetBorderColori)(b,signed_color);
    P(nvnSamplerBuilderGetBorderColori)(b,got_i);P(nvnSamplerBuilderGetBorderColorui)(b,got_u);P(nvnSamplerBuilderGetBorderColor)(b,got_f);
    EXPECT("signed border exact words",0,memcmp(signed_color,got_i,16)|memcmp(signed_color,got_u,16)|memcmp(signed_color,got_f,16));
    EXPECT("sampler initialize",1,P(nvnSamplerInitialize)(&a,b));
    copy=a;
    uint64_t serial=P(nvnSamplerGetDebugID)(&a);
    EXPECT("sampler copy retains lifetime ID",1,serial && serial==P(nvnSamplerGetDebugID)(&copy));
    P(nvnSamplerBuilderSetDefaults)(b);
    EXPECT("sampler defaults preserve device",(uintptr_t)&dev,(uintptr_t)P(nvnSamplerBuilderGetDevice)(b));
    EXPECT("initialized sampler independent of builder",1,P(nvnSamplerGetReductionFilter)(&a));
    P(nvnSamplerGetBorderColori)(&a,got_i);P(nvnSamplerGetBorderColorui)(&a,got_u);
    EXPECT("object border exact words",0,memcmp(signed_color,got_i,16)|memcmp(signed_color,got_u,16));
    const uint32_t unsigned_color[4]={0xffffffff,0x80000000,0x7fc01234,0x3f800000};
    P(nvnSamplerBuilderSetBorderColorui)(b,unsigned_color);P(nvnSamplerBuilderGetBorderColorui)(b,got_u);
    EXPECT("unsigned border exact words including NaN bits",0,memcmp(unsigned_color,got_u,16));
    EXPECT("sampler reinitialize",1,P(nvnSamplerInitialize)(&a,b));
    EXPECT("sampler reinitialize changes lifetime ID",1,serial!=P(nvnSamplerGetDebugID)(&a));
    EXPECT("sampler compare includes reduction/snap",0,P(nvnSamplerCompare)(&a,&copy));
    EXPECT("sampler builder guard bytes",1,guarded.before==0x12345678 && guarded.after==0xabcdef);
    // Exercise the builder overload through its registered thunk as well.
    NVNsamplerPool pool={0};
    P(nvnSamplerPoolRegisterSamplerBuilder)(&pool,7,b);
    P(nvnSamplerFinalize)(&a);P(nvnSamplerFinalize)(&copy);
}
