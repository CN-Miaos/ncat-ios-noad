// 钩子逻辑自测（macOS 上跑同一份 noad.m，不需要 iPhone）
// 断言 1：*.capi 的广告配置请求被拦，返回我们合成的 JSON（不联网）
// 断言 2：其它 .capi 走放行分支（这里故意给个不存在的主机，应报网络错误而不是我们合成的内容）
#import <Foundation/Foundation.h>

static int done = 0, fail = 0;

static void check(BOOL cond, const char *msg) {
    printf("%s %s\n", cond ? "PASS" : "FAIL", msg);
    if (!cond) fail++;
}

static NSData *fetch(NSString *url) {
    __block NSData *result = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *t = [[NSURLSession sharedSession]
        dataTaskWithURL:[NSURL URLWithString:url]
      completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        result = d; err = e; dispatch_semaphore_signal(sem);
    }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (err) printf("   (network: %s)\n", err.localizedDescription.UTF8String);
    return result;
}

int main(void) {
    @autoreleasepool {
        NSString *blocked = [[NSString alloc] initWithData:
            fetch(@"https://127.0.0.1:9/v2/config/uniqx.capi") encoding:NSUTF8StringEncoding];
        check(blocked != nil && [blocked containsString:@"\"data\":{}"],
              "广告配置接口被拦截，返回合成 JSON");

        NSString *passthrough = [[NSString alloc] initWithData:
            fetch(@"https://127.0.0.1:9/v4/vod/home.capi") encoding:NSUTF8StringEncoding];
        check(!(passthrough && [passthrough containsString:@"\"data\":{}"]),
              "其它 .capi 未被误拦（走放行分支）");

        NSString *normal = [[NSString alloc] initWithData:
            fetch(@"https://127.0.0.1:9/normal/path") encoding:NSUTF8StringEncoding];
        check(!(normal && [normal containsString:@"\"data\":{}"]), "非 .capi 请求不受影响");
    }
    printf("\n%s (%d failed)\n", fail ? "TEST FAILED" : "ALL PASSED", fail);
    return fail ? 1 : 0;
}
