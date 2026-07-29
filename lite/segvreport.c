/* Chained SIGSEGV reporter for the juliac Lambda bundles.
 *
 * Julia's crash handler prints a backtrace only for threads with a Julia task
 * context; a fault on a foreign thread (libuv pool, curl resolver) yields just
 * the "[pid] signal 11" header — no ip, no frames. This shim runs first,
 * writes tid / thread name / fault address / RIP / a glibc backtrace to
 * stderr, then chains to Julia's handler unchanged.
 *
 * Quietness: only SEGV_MAPERR faults are reported. Julia's GC safepoint and
 * write-barrier faults hit mprotected-but-mapped pages (SEGV_ACCERR), so
 * routine VM operation never logs. Installed *after* jl_init (from
 * lambda_loop) so Julia's own handler is the one we chain to.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <execinfo.h>
#include <sys/syscall.h>
#include <sys/prctl.h>
#include <ucontext.h>

static struct sigaction segvreport_prev;

static void segvreport_handler(int sig, siginfo_t *si, void *uc_)
{
    if (si->si_code == SEGV_MAPERR) {
        ucontext_t *uc = (ucontext_t *)uc_;
        char comm[24];
        memset(comm, 0, sizeof comm);
        prctl(PR_GET_NAME, (unsigned long)comm, 0, 0, 0);
        char buf[256];
        int n = snprintf(buf, sizeof buf,
                         "SEGVREPORT tid=%ld comm=%s addr=%p ip=%p\n",
                         (long)syscall(SYS_gettid), comm, si->si_addr,
                         (void *)uc->uc_mcontext.gregs[REG_RIP]);
        if (n > 0)
            write(2, buf, (size_t)n);
        /* async-signal-unsafe, but the process is dying anyway */
        void *bt[32];
        int m = backtrace(bt, 32);
        backtrace_symbols_fd(bt, m, 2);
    }
    if (segvreport_prev.sa_flags & SA_SIGINFO) {
        segvreport_prev.sa_sigaction(sig, si, uc_);
    } else if (segvreport_prev.sa_handler == SIG_DFL) {
        signal(sig, SIG_DFL);
        raise(sig);
    } else if (segvreport_prev.sa_handler != SIG_IGN) {
        segvreport_prev.sa_handler(sig);
    }
}

void install_segv_reporter(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = segvreport_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &segvreport_prev);
}
