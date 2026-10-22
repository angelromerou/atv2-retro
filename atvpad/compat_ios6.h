// Force-included into the BTstack build: iOS 6 has no clock_gettime (added in iOS 10).
#ifndef COMPAT_IOS6_H
#define COMPAT_IOS6_H
#include <time.h>
#include <mach/mach_time.h>
#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 6
static inline int clock_gettime_ios6(int clk, struct timespec *ts) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    uint64_t ns = mach_absolute_time() * tb.numer / tb.denom;
    ts->tv_sec = ns / 1000000000; ts->tv_nsec = ns % 1000000000;
    return 0;
}
#define clock_gettime clock_gettime_ios6
#endif
#endif
