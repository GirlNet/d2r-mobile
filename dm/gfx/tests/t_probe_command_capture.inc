// 诊断捕获回归：通过实际静态跳板传入标量位和空资源引用，不执行资源访问或 GPU 工作。
// Capture regressions use actual static thunks with scalar bits and null resource references, without resource accesses or GPU work.
static int test_probe_command_capture(void) {
gpa=(PFNNVNDEVICEGETPROCADDRESSPROC)h_nvnBootstrapLoader("nvnDeviceGetProcAddress");NVNcommandBuffer command;P(nvnCommandBufferInitialize)(&command,&dev);
P(nvnCommandBufferBindTransformFeedbackBuffer)(&command,(int)257,(NVNbufferAddress)257,(size_t)257);
P(nvnCommandBufferBindTransformFeedbackBuffers)(&command,(int)257,(int)257,NULL);
P(nvnCommandBufferSetPatchSize)(&command,(int)257);
P(nvnCommandBufferSetInnerTessellationLevels)(&command,NULL);
P(nvnCommandBufferSetOuterTessellationLevels)(&command,NULL);
P(nvnCommandBufferBeginTransformFeedback)(&command,(NVNbufferAddress)257);
P(nvnCommandBufferEndTransformFeedback)(&command,(NVNbufferAddress)257);
P(nvnCommandBufferPauseTransformFeedback)(&command,(NVNbufferAddress)257);
P(nvnCommandBufferResumeTransformFeedback)(&command,(NVNbufferAddress)257);
P(nvnCommandBufferDrawTransformFeedback)(&command,(NVNdrawPrimitive)257,(NVNbufferAddress)257);
P(nvnCommandBufferDrawArraysIndirect)(&command,(NVNdrawPrimitive)257,(NVNbufferAddress)257);
P(nvnCommandBufferDrawElementsIndirect)(&command,(NVNdrawPrimitive)257,(NVNindexType)257,(NVNbufferAddress)257,(NVNbufferAddress)257);
P(nvnCommandBufferMultiDrawArraysIndirectCount)(&command,(NVNdrawPrimitive)257,(NVNbufferAddress)257,(NVNbufferAddress)257,(int)257,(ptrdiff_t)257);
P(nvnCommandBufferMultiDrawElementsIndirectCount)(&command,(NVNdrawPrimitive)257,(NVNindexType)257,(NVNbufferAddress)257,(NVNbufferAddress)257,(NVNbufferAddress)257,(int)257,(ptrdiff_t)257);
P(nvnCommandBufferClearColori)(&command,(int)257,NULL,(int)257);
P(nvnCommandBufferClearColorui)(&command,(int)257,NULL,(int)257);
P(nvnCommandBufferDispatchComputeIndirect)(&command,(NVNbufferAddress)257);
P(nvnCommandBufferDiscardColor)(&command,(int)257);
P(nvnCommandBufferDiscardDepthStencil)(&command);
P(nvnCommandBufferTiledDownsample)(&command,NULL,NULL);
P(nvnCommandBufferDownsampleTextureView)(&command,NULL,NULL,NULL,NULL);
P(nvnCommandBufferTiledDownsampleTextureView)(&command,NULL,NULL,NULL,NULL);
P(nvnCommandBufferSaveZCullData)(&command,(NVNbufferAddress)257,(size_t)257);
P(nvnCommandBufferRestoreZCullData)(&command,(NVNbufferAddress)257,(size_t)257);
P(nvnCommandBufferDrawTexture)(&command,(NVNtextureHandle)257,NULL,NULL);
P(nvnCommandBufferSetProgramSubroutines)(&command,NULL,(NVNshaderStage)257,(const int)257,(const int)257,NULL);
P(nvnCommandBufferBindCoverageModulationTable)(&command,NULL);
P(nvnCommandBufferResolveDepthBuffer)(&command);
P(nvnCommandBufferWaitEvent)(&command,NULL,(NVNeventWaitMode)257,(uint32_t)257);
const char *names[]={
    "nvnCommandBufferBindTransformFeedbackBuffer",
    "nvnCommandBufferBindTransformFeedbackBuffers",
    "nvnCommandBufferSetPatchSize",
    "nvnCommandBufferSetInnerTessellationLevels",
    "nvnCommandBufferSetOuterTessellationLevels",
    "nvnCommandBufferBeginTransformFeedback",
    "nvnCommandBufferEndTransformFeedback",
    "nvnCommandBufferPauseTransformFeedback",
    "nvnCommandBufferResumeTransformFeedback",
    "nvnCommandBufferDrawTransformFeedback",
    "nvnCommandBufferDrawArraysIndirect",
    "nvnCommandBufferDrawElementsIndirect",
    "nvnCommandBufferMultiDrawArraysIndirectCount",
    "nvnCommandBufferMultiDrawElementsIndirectCount",
    "nvnCommandBufferClearColori",
    "nvnCommandBufferClearColorui",
    "nvnCommandBufferDispatchComputeIndirect",
    "nvnCommandBufferDiscardColor",
    "nvnCommandBufferDiscardDepthStencil",
    "nvnCommandBufferTiledDownsample",
    "nvnCommandBufferDownsampleTextureView",
    "nvnCommandBufferTiledDownsampleTextureView",
    "nvnCommandBufferSaveZCullData",
    "nvnCommandBufferRestoreZCullData",
    "nvnCommandBufferDrawTexture",
    "nvnCommandBufferSetProgramSubroutines",
    "nvnCommandBufferBindCoverageModulationTable",
    "nvnCommandBufferResolveDepthBuffer",
    "nvnCommandBufferWaitEvent",
};unsigned covered=0;for(unsigned i=0;i<sizeof names/sizeof *names;i++){unsigned j=0;while(j<NVN_NFUNC && strcmp(nvn_names[j],names[i]))j++;if(j<NVN_NFUNC && atomic_load(&nvn_slot[j].cnt)>0)covered++;}
if(covered!=sizeof names/sizeof *names)return 1;printf("NVN PROBE CAPTURE OK: %u typed calls recorded; no guest GPU work\n",covered);return 0;
}
