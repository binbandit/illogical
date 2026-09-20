// Read-only macOS process counters. No tracing entitlement or target mutation.
#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <time.h>

struct sample {
    struct rusage_info_v6 usage;
    int flavor;
    int threads;
    uint64_t monotonic_ns;
};

static uint64_t ticks_to_ns(uint64_t ticks) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    return (uint64_t)((__uint128_t)ticks * timebase.numer / timebase.denom);
}

static int read_sample(int pid, struct sample *sample) {
    memset(sample, 0, sizeof(*sample));
    sample->flavor = RUSAGE_INFO_V6;
    if (proc_pid_rusage(pid, sample->flavor, (rusage_info_t *)&sample->usage)) {
        sample->flavor = RUSAGE_INFO_V4;
        if (proc_pid_rusage(pid, sample->flavor, (rusage_info_t *)&sample->usage)) return -1;
    }
    struct proc_taskinfo task;
    sample->threads = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)
        ? task.pti_threadnum : -1;
    sample->monotonic_ns = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    return 0;
}

static void print_sample(const struct sample *sample) {
    const struct rusage_info_v6 *u = &sample->usage;
    printf("{\"flavor\":%d,\"monotonic_ns\":%" PRIu64
           ",\"process_start_abstime\":%" PRIu64 ",\"user_ns\":%" PRIu64
           ",\"system_ns\":%" PRIu64 ",\"package_idle_wakeups\":%" PRIu64
           ",\"interrupt_wakeups\":%" PRIu64 ",\"rss_bytes\":%" PRIu64
           ",\"footprint_bytes\":%" PRIu64 ",\"max_footprint_bytes\":%" PRIu64
           ",\"disk_read_bytes\":%" PRIu64 ",\"disk_write_bytes\":%" PRIu64
           ",\"logical_write_bytes\":%" PRIu64 ",\"instructions\":%" PRIu64
           ",\"cycles\":%" PRIu64 ",\"threads\":%d,\"energy_nj\":",
           sample->flavor, sample->monotonic_ns, u->ri_proc_start_abstime,
           ticks_to_ns(u->ri_user_time), ticks_to_ns(u->ri_system_time), u->ri_pkg_idle_wkups,
           u->ri_interrupt_wkups, u->ri_resident_size, u->ri_phys_footprint,
           u->ri_lifetime_max_phys_footprint, u->ri_diskio_bytesread,
           u->ri_diskio_byteswritten, u->ri_logical_writes, u->ri_instructions,
           u->ri_cycles, sample->threads);
    if (sample->flavor == RUSAGE_INFO_V6) printf("%" PRIu64, u->ri_energy_nj);
    else printf("null");
    printf("}");
}

int main(int argc, char **argv) {
    int pid = 0;
    double seconds = 0;
    for (int i = 1; i < argc; i++) {
        char *end = NULL;
        if (!strcmp(argv[i], "--pid") && i + 1 < argc) {
            long value = strtol(argv[++i], &end, 10);
            if (!end || *end || value <= 0 || value > INT32_MAX) return 2;
            pid = (int)value;
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            seconds = strtod(argv[++i], &end);
            if (!end || *end || !(seconds > 0 && seconds <= 60)) return 2;
        } else { fprintf(stderr, "Usage: %s --pid PID [--seconds 0<N<=60]\n", argv[0]); return 2; }
    }
    if (!pid) return 2;
    struct sample first, last;
    if (read_sample(pid, &first)) { perror("proc_pid_rusage"); return 1; }
    printf("{\"pid\":%d,\"sample\":", pid); print_sample(&first);
    if (seconds > 0) {
        struct timespec delay = {.tv_sec = (time_t)seconds,
            .tv_nsec = (long)((seconds - (time_t)seconds) * 1e9)};
        while (nanosleep(&delay, &delay) && errno == EINTR) { }
        if (read_sample(pid, &last)) { perror("proc_pid_rusage"); return 1; }
        if (first.usage.ri_proc_start_abstime != last.usage.ri_proc_start_abstime) {
            fprintf(stderr, "PID was reused during measurement\n"); return 1;
        }
        const struct rusage_info_v6 *a = &first.usage, *b = &last.usage;
        double elapsed = (double)(last.monotonic_ns - first.monotonic_ns) / 1e9;
        printf(",\"end\":"); print_sample(&last);
        printf(",\"delta\":{\"elapsed_seconds\":%.6f,\"cpu_seconds\":%.9f,"
               "\"cpu_percent_one_core\":%.6f,\"package_idle_wakeups\":%" PRIu64
               ",\"interrupt_wakeups\":%" PRIu64 ",\"footprint_bytes\":%" PRId64
               ",\"disk_read_bytes\":%" PRIu64 ",\"disk_write_bytes\":%" PRIu64
               ",\"logical_write_bytes\":%" PRIu64 "}", elapsed,
               (double)ticks_to_ns(b->ri_user_time - a->ri_user_time + b->ri_system_time - a->ri_system_time) / 1e9,
               (double)ticks_to_ns(b->ri_user_time - a->ri_user_time + b->ri_system_time - a->ri_system_time) / 1e9 / elapsed * 100,
               b->ri_pkg_idle_wkups - a->ri_pkg_idle_wkups,
               b->ri_interrupt_wkups - a->ri_interrupt_wkups,
               (int64_t)b->ri_phys_footprint - (int64_t)a->ri_phys_footprint,
               b->ri_diskio_bytesread - a->ri_diskio_bytesread,
               b->ri_diskio_byteswritten - a->ri_diskio_byteswritten,
               b->ri_logical_writes - a->ri_logical_writes);
    }
    printf("}\n");
    return 0;
}
