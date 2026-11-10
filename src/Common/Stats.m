//
//  Common/Stats.m
//

#import "Stats.h"
#import "Rewriter.h"
#import <sys/time.h>
#import <stdint.h>
#import <pthread.h>

static int    g_known = 0;
static int    g_generic = 0;
static int    g_reward = 0, g_play = 0, g_fail = 0, g_skipped = 0;
static int    g_exact = 0;
static int    g_rewards = 0;
static double g_start = 0;

static double ck_now(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

void CKStatsMarkStart(void) {
    if (g_start == 0) g_start = ck_now();
}

void CKStatsSetAdScan(int known, int generic) {
    g_known = known;
    g_generic = generic;
}

void CKStatsSetHookResult(int reward, int play, int fail, int skipped) {
    g_reward = reward;
    g_play   = play;
    g_fail   = fail;
    g_skipped = skipped;
}

void CKStatsSetExactSlots(int n) { g_exact = n; }

void CKStatsCountRewardFired(void) { g_rewards++; }

// ---- 补发链诊断 ----
static int g_scheduleCount = 0;
static int g_attemptCount  = 0;
static NSString *g_lastReason = nil;
static pthread_mutex_t g_reasonLock = PTHREAD_MUTEX_INITIALIZER;

void CKStatsCountSchedule(void) { g_scheduleCount++; }
void CKStatsCountAttempt(void)  { g_attemptCount++; }
void CKStatsSetRewardReason(NSString *reason) {
    pthread_mutex_lock(&g_reasonLock);
    g_lastReason = reason ? [reason copy] : nil;
    pthread_mutex_unlock(&g_reasonLock);
}
int CKStatsScheduleCount(void) { return g_scheduleCount; }
int CKStatsAttemptCount(void)  { return g_attemptCount; }
NSString *CKStatsLastRewardReason(void) {
    pthread_mutex_lock(&g_reasonLock);
    NSString *r = g_lastReason ?: @"—";
    pthread_mutex_unlock(&g_reasonLock);
    return r;
}

CKStatsSnapshot CKStatsGet(void) {
    CKStatsSnapshot s;
    memset(&s, 0, sizeof(s));
    s.knownClasses   = g_known;
    s.genericClasses = g_generic;
    s.rewardHooks    = g_reward;
    s.playHooks      = g_play;
    s.failHooks      = g_fail;
    s.skipped        = g_skipped;
    s.exactSlots     = g_exact;
    s.ecpmHits       = (int)CKRewriteHitCount();
    s.rewardsFired   = g_rewards;
    s.uptime         = g_start > 0 ? (ck_now() - g_start) : 0;
    return s;
}
