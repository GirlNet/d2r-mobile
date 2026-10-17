// The real adapters must keep all legacy BSD calls offline, preserve failure
// outputs, isolate errno between threads and never dereference SDK IPC objects.
#include "../hle_net.c"
#include "../hle_account.c"
#include <assert.h>
#include <stdatomic.h>

static unsigned signals;
void hle_signal_system_event(void *event) { assert(event == (void *)0x1234); signals++; }
static void *errno_worker(void *unused) {
    (void)unused;
    h_nsk_SetErrno(71);
    assert(h_sk_GetErrnoLegacy() == 71);
    assert(h_sk_SocketLegacy(2, 1, 0) == -1);
    assert(h_sk_GetErrnoLegacy() == 50);
    return NULL;
}
int main(void) {
    assert(h_sk_InitLegacy(NULL, 0, 0, 0) == 0);
    uint8_t output[128]; memset(output, 0xa5, sizeof output);
    unsigned length = sizeof output;
    assert(h_sk_SocketLegacy(2, 1, 6) == -1);
    assert(h_sk_BindLegacy(1, output, length) == -1);
    assert(h_sk_ConnectLegacy(1, output, length) == -1);
    assert(h_sk_AcceptLegacy(1, output, &length) == -1);
    assert(h_sk_GetSockNameLegacy(1, output, &length) == -1);
    assert(h_sk_GetSockOptLegacy(1, 2, 3, output, &length) == -1);
    assert(h_sk_SetSockOptLegacy(1, 2, 3, output, length) == -1);
    assert(h_sk_SetSockOptIntLegacy(1, 2, 3, output, length) == -1);
    assert(h_sk_PollLegacy(output, 4, 0) == -1);
    assert(h_sk_FcntlLegacy(1, 0) == -1);
    assert(h_sk_ShutdownLegacy(1, 2) == -1);
    assert(h_sk_RecvLegacy(1, output, 128, 0) == -1);
    assert(h_sk_SendLegacy(1, output, 128, 0) == -1);
    assert(h_sk_RecvFromLegacy(1, output, 128, 0, output, &length) == -1);
    assert(h_sk_SendToLegacy(1, output, 128, 0, output, length) == -1);
    assert(h_sk_SendTo(1, output, 128, 0, output, length) == -1);
    assert(length == sizeof output);
    for (unsigned i = 0; i < sizeof output; i++) assert(output[i] == 0xa5);
    void *resolved = output;
    assert(h_sk_GetAddrInfoLegacy("invalid", "80", NULL, &resolved) == 4 && !resolved);
    h_sk_FreeAddrInfoLegacy(NULL);
    assert(h_sk_GetErrnoLegacy() == 50);
    h_nsk_SetErrno(17);
    pthread_t worker; assert(!pthread_create(&worker, NULL, errno_worker, NULL));
    assert(!pthread_join(worker, NULL)); assert(h_sk_GetErrnoLegacy() == 17);
    assert(h_nifm_SubmitWait() != 0);
    uint32_t ip = 0xffffffff; assert(h_nifm_GetIpLegacy(&ip) != 0 && ip == 0);

    // Poison pointers prove these completed offline contexts do not touch SDK
    // service vtables. Boolean outputs must write only a single byte.
    void *poison = (void *)(uintptr_t)1;
    h_acc_AcCtor(poison); h_acc_AcDtor(poison);
    uint8_t done[3] = {0xa5, 0, 0x5a};
    assert(h_acc_AcDone(poison, done + 1) == 0 && done[1] == 1);
    assert(done[0] == 0xa5 && done[2] == 0x5a);
    assert(h_acc_AcCancel(poison) == 0 && h_acc_AcGetRes(poison) != 0);
    assert(h_acc_AcGetEv(poison, (void *)0x1234) == 0 && signals == 1);
    Uid uid = {{0}};
    assert(h_acc_Exists(done + 1, &uid) == 0 && done[1] == 0);
    uid = k_uid;
    assert(h_acc_Exists(done + 1, &uid) == 0 && done[1] == 1);
    assert(done[0] == 0xa5 && done[2] == 0x5a);
    UserHandle token; assert(h_acc_TryOpenPre(&token));
    UserHandle before = token; h_acc_CloseUser(&token);
    assert(!memcmp(&token, &before, sizeof token)); // CloseUser takes a const token.
    puts("OFFLINE SERVICES OK: legacy socket ABIs, preserved outputs, resolver failure, thread-local errno, completed async lifecycle, byte boolean guards and local-user tokens");
    return 0;
}
