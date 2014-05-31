#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <asm/unistd.h>
#include <sys/ptrace.h>
#include <sys/types.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

#include "syscall-hash.h"

#define MAX_SYSCALL_NO 315

// XXX error handling
// XXX check that ptrace functions all work as intended during configure
// XXX assert that PL_sig_pending and PL_psig_pend are word-aligned?
// XXX what if multiple syscalls occur in an interval?

static int my_custom_signal = 0;
static int channel[2];
static int watching_syscall[MAX_SYSCALL_NO + 1];

static void
pstrcpy(char *dst, size_t dst_size, pid_t child, void *addr)
{
    size_t offset = 0;
    union {
        long l;
        char c[sizeof(long)];
    } u;

    memset(u.c, 0xff, sizeof(long));

    while(!memchr(u.c, 0, sizeof(long))) {
        u.l = ptrace(PTRACE_PEEKDATA, child, addr + offset * sizeof(void *), 0);
        memcpy(dst + offset * sizeof(void *), u.c, sizeof(void *));
        offset++;
    }
}

static void
handle_syscall_enter(pid_t child)
{
    struct user userdata;
    uint16_t syscall_no;

#if __sparc__
    ptrace(PTRACE_GETREGS, child, &userdata, 0);
#else
    ptrace(PTRACE_GETREGS, child, 0, &userdata);
#endif

    // XXX arch-specific
    syscall_no = userdata.regs.orig_rax;

    if(watching_syscall[syscall_no]) {
        // XXX fun with alignment
        ptrace(PTRACE_POKEDATA, child, (void *) &my_custom_signal, 1);
        write(channel[1], &syscall_no, sizeof(uint16_t)); // XXX error checking, chance of EPIPE?
    }
}

static void
handle_syscall_exit(pid_t child)
{
    // no-op (for now)
}

static void
run_parent(pid_t child)
{
    int status;
    int enter;

    waitpid(child, &status, 0);

    ptrace(PTRACE_SETOPTIONS, child, 0, PTRACE_O_EXITKILL | PTRACE_O_TRACESYSGOOD);
    ptrace(PTRACE_SYSCALL, child, 0, 0);

    while(waitpid(child, &status, 0) >= 0) {
        if(WIFSTOPPED(status) && WSTOPSIG(status) == (SIGTRAP | 0x80)) {
            if(enter) {
                handle_syscall_enter(child);
            } else {
                handle_syscall_exit(child);
            }
            enter = !enter;
        }
        ptrace(PTRACE_SYSCALL, child, 0, 0);
    }
}

static uint16_t
read_event(int fd)
{
    uint16_t syscall_no;

    // XXX proper error handling
    if(read(fd, &syscall_no, sizeof(uint16_t)) > 0) {
        return syscall_no;
    } else {
        return 0;
    }
}

MODULE = Devel::Trace::Syscall PACKAGE = Devel::Trace::Syscall

void
import(...)
    INIT:
        int i;
        pid_t child;
    CODE:
    {
        memset(watching_syscall, 0, sizeof(watching_syscall));
        for(i = 1; i < items; i++) {
            const char *syscall_name   = SvPVutf8_nolen(ST(i));
            const struct syscall *info = syscall_lookup(syscall_name, strlen(syscall_name));

            if(info) {
                printf("requesting trace on %d\n", info->syscall_no);
                watching_syscall[info->syscall_no] = 1;
            } else {
                // XXX get mad
            }
        }

        pipe(channel);
        child = fork();

        if(child == -1) {
            Perl_croak("failed to fork!"); // XXX reason
        }

        if(child) {
            close(channel[0]);
            fcntl(channel[1], F_SETFL, O_NONBLOCK);
            run_parent(child);
            my_exit(0);
        } else {
            close(channel[1]);
            fcntl(channel[0], F_SETFL, O_NONBLOCK);
            ptrace(PTRACE_TRACEME, 0, 0, 0);
            raise(SIGTRAP);
            XSRETURN_UNDEF;
        }
    }

void
flush_events(SV *trace)
    CODE:
        if(UNLIKELY(my_custom_signal)) {
            char *trace_chars = SvPVutf8_nolen(trace);
            uint16_t syscall_no;

            my_custom_signal = 0;

            while(syscall_no = read_event(channel[0])) {
                char *syscall_name = "open";
                printf("%s%s", syscall_name, trace_chars);
            }
        }
