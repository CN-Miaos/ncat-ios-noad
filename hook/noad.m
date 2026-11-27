// 网飞猫 iOS 去广告 hook（试点版）
// 机制：进程内注册 NSURLProtocol，拦截 *.capi 请求
//   1) /config/ 类接口 → 返回空壳，App 走「广告未配置」分支
//   2) 其余接口 → 原样放行，但把响应前 120 字节打进日志（判断是否明文 JSON）
#import <Foundation/Foundation.h>

static NSString *const kHandled = @"NoadHandledKey";

@interface NoadProtocol : NSURLProtocol
@end

@implementation NoadProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *u = request.URL.absoluteString ?: @"";
    if ([u rangeOfString:@".capi"].location == NSNotFound) return NO;
    if ([NSURLProtocol propertyForKey:kHandled inRequest:request]) return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandled inRequest:req];
    NSString *path = req.URL.path ?: @"";

    // 只砍广告位配置：/v2/config/units.capi（已改名 uniqx）。appInit 等要放行，否则 App 起不来
    BOOL isAdUnit = ([path rangeOfString:@"config/uniq"].location != NSNotFound);
    if (isAdUnit) {
        NSData *body = [@"{\"code\":0,\"msg\":\"ok\",\"data\":{}}" dataUsingEncoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc]
            initWithURL:req.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
            headerFields:@{ @"Content-Type" : @"application/json",
                            @"Content-Length" : [NSString stringWithFormat:@"%lu", (unsigned long)body.length] }];
        [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:body];
        [self.client URLProtocolDidFinishLoading:self];
        NSLog(@"[noad] blocked %@", path);
        return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.protocolClasses = @[];   // 防递归
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { [self.client URLProtocol:self didFailWithError:err]; return; }
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }
        [self.client URLProtocol:self didLoadData:data ?: [NSData data]];
        [self.client URLProtocolDidFinishLoading:self];
        NSString *head = @"<binary>";
        if (data.length) {
            NSUInteger n = MIN(data.length, (NSUInteger)120);
            NSString *s = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, n)]
                                                encoding:NSUTF8StringEncoding];
            if (s) head = s;
        }
        NSLog(@"[noad] pass %@ len=%lu head=%@", path, (unsigned long)data.length, head);
    }] resume];
}

- (void)stopLoading {}

@end

__attribute__((constructor)) static void noad_init(void) {
    [NSURLProtocol registerClass:[NoadProtocol class]];
    NSLog(@"[noad] dylib loaded, NSURLProtocol registered");
}
