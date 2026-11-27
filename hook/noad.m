// 网飞猫 iOS 补丁 — v4（诊断版）
// 目的：先确认「钩子到底有没有被加载」，再谈去广告是否生效。
//   1) 启动 2 秒后窗口顶部弹一条「喵神补丁 v4 已加载」，3 秒自动消失 —— 肉眼验证
//   2) 把每个请求的 host+path 打一遍（同路径只打一次）+ 每个响应前 80 字节 + 顶层 JSON 键
//     → 用日志看清内容到底是接口下发、还是 H5 页面里的
//   3) 原有逻辑全部保留：广告配置空壳 / 成人条目过滤 / banner 换图 / 资料卡品牌化
#import <Foundation/Foundation.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

static NSString *const kBannerURL =
    @"https://cdn.jsdelivr.net/gh/CN-Miaos/Miaos.github.io@master/ncat/banner.jpg";
static NSString *const kAvatarURL =
    @"https://cdn.jsdelivr.net/gh/CN-Miaos/Miaos.github.io@master/ncat/avatar.png";
static NSString *const kNickname = @"Miaos喵神";
static NSString *const kSignature = @"永久SVIP · 做点好东西";
static NSString *const kHandled = @"NoadHandledKey";

static NSMutableSet *seenPaths(void) {
    static NSMutableSet *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [NSMutableSet set]; });
    return s;
}

static NSArray<NSString *> *adultWords(void) {
    static NSArray *w; static dispatch_once_t o;
    dispatch_once(&o, ^{ w = @[ @"成人", @"福利", @"伦理", @"18禁", @"里番", @"无码", @"三级", @"情色", @"午夜",
                                @"黄", @"裸", @"AV", @"博彩", @"棋牌", @"开元" ]; });
    return w;
}

static NSArray<NSString *> *dropKeys(void) {
    static NSArray *k; static dispatch_once_t o;
    dispatch_once(&o, ^{ k = @[ @"bannerAD", @"startAD", @"pauseAD", @"adList", @"adInfo", @"ads",
                                @"ad", @"adUnit", @"adUnits", @"adSource", @"adSwitch", @"adConfig" ]; });
    return k;
}

static NSArray<NSString *> *titleKeys(void) {
    return @[ @"vod_name", @"vodName", @"name", @"title", @"vod_title" ];
}
static NSArray<NSString *> *imageKeys(void) {
    return @[ @"image", @"img", @"pic", @"cover", @"vod_pic", @"vodPic" ];
}

static BOOL looksAdult(NSDictionary *item) {
    id f = item[@"isAdult"];
    if (f && [f respondsToSelector:@selector(boolValue)] && [f boolValue]) return YES;
    for (NSString *k in @[ @"type_name", @"typeName", @"channelName", @"className", @"category" ]) {
        id v = item[k];
        if (![v isKindOfClass:[NSString class]]) continue;
        for (NSString *w in adultWords()) if ([v rangeOfString:w].location != NSNotFound) return YES;
    }
    for (NSString *k in titleKeys()) {
        id v = item[k];
        if (![v isKindOfClass:[NSString class]]) continue;
        for (NSString *w in adultWords()) if ([v rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL hasTitle(NSDictionary *item) {
    for (NSString *k in titleKeys()) if (item[k]) return YES;
    return NO;
}

static void spoofProfile(NSMutableDictionary *d) {
    BOOL hasNick = [d[@"nickname"] isKindOfClass:[NSString class]] || [d[@"user_nickname"] isKindOfClass:[NSString class]];
    BOOL hasAva  = [d[@"avatar"] isKindOfClass:[NSString class]] || [d[@"user_avatar"] isKindOfClass:[NSString class]];
    BOOL hasSig  = [d[@"signature"] isKindOfClass:[NSString class]];
    if (!hasNick && !hasAva) return;
    for (NSString *k in @[ @"nickname", @"user_nickname" ]) if (d[k]) d[k] = kNickname;
    for (NSString *k in @[ @"avatar", @"user_avatar" ]) if (d[k]) d[k] = kAvatarURL;
    if (hasNick && hasSig) for (NSString *k in @[ @"signature", @"signatureText", @"intro" ]) if (d[k]) d[k] = kSignature;
}

static id scrub(id obj) {
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id e in (NSArray *)obj) {
            if ([e isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dd = (NSDictionary *)e;
                if (hasTitle(dd) && looksAdult(dd)) continue;
                [out addObject:scrub(dd)];
            } else {
                id s = scrub(e);
                if (s) [out addObject:s];
            }
        }
        return out;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        for (NSString *k in (NSDictionary *)obj) {
            if ([dropKeys() containsObject:k]) continue;
            id v = scrub(((NSDictionary *)obj)[k]);
            if (v) out[k] = v;
        }
        for (NSString *bk in @[ @"banners", @"bannerList", @"banner_list" ]) {
            id arr = out[bk];
            if (![arr isKindOfClass:[NSArray class]] || [arr count] == 0) continue;
            id first = ((NSArray *)arr)[0];
            if (![first isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *b = [first mutableCopy];
            BOOL replaced = NO;
            for (NSString *ik in imageKeys()) if (b[ik]) { b[ik] = kBannerURL; replaced = YES; }
            if (!replaced) continue;
            for (NSString *lk in @[ @"url", @"link", @"jumpUrl", @"target" ]) if (b[lk]) b[lk] = @"";
            out[bk] = @[ b ];
        }
        spoofProfile(out);
        return out;
    }
    return obj;
}

static NSData *scrubJSON(NSData *data, NSString *path) {
    if (!data.length) return data;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (!json) return data;
    if ([json isKindOfClass:[NSDictionary class]]) {
        NSArray *keys = [(NSDictionary *)json allKeys];
        NSLog(@"[noad] JSON %@ keys=%@", path, [keys componentsJoinedByString:@","]);
    }
    id clean = scrub(json);
    NSData *out = [NSJSONSerialization dataWithJSONObject:clean options:0 error:NULL];
    return out.length ? out : data;
}

@interface NoadProtocol : NSURLProtocol
@end

@implementation NoadProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:kHandled inRequest:request]) return NO;
    NSString *u = request.URL.absoluteString ?: @"";
    if ([u rangeOfString:@".capi"].location != NSNotFound) return YES;
    if ([(request.URL.path ?: @"") hasPrefix:@"/user"]) return YES;
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandled inRequest:req];
    NSString *path = req.URL.path ?: @"";

    if ([path rangeOfString:@"config/uniq"].location != NSNotFound) {
        NSData *body = [@"{\"code\":0,\"msg\":\"ok\",\"data\":{}}" dataUsingEncoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc]
            initWithURL:req.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
            headerFields:@{ @"Content-Type" : @"application/json",
                            @"Content-Length" : [NSString stringWithFormat:@"%lu", (unsigned long)body.length] }];
        [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:body];
        [self.client URLProtocolDidFinishLoading:self];
        NSLog(@"[noad] BLOCKED %@", path);
        return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.protocolClasses = @[];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { [self.client URLProtocol:self didFailWithError:err]; return; }
        NSData *out = scrubJSON(data, path);

        NSHTTPURLResponse *hr = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        NSMutableDictionary *h = [hr.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
        [h removeObjectForKey:@"Content-Encoding"];
        h[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)out.length];
        NSHTTPURLResponse *fixed = [[NSHTTPURLResponse alloc]
            initWithURL:req.URL statusCode:hr ? hr.statusCode : 200 HTTPVersion:@"HTTP/1.1" headerFields:h];
        [self.client URLProtocol:self didReceiveResponse:fixed cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:out ?: [NSData data]];
        [self.client URLProtocolDidFinishLoading:self];

        NSString *head = @"<binary>";
        if (data.length) {
            NSUInteger n = MIN(data.length, (NSUInteger)80);
            NSString *s = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, n)] encoding:NSUTF8StringEncoding];
            if (s) head = s;
        }
        NSLog(@"[noad] PASS %@ %lu→%lu head=%@", path,
              (unsigned long)(data ? data.length : 0), (unsigned long)out.length, head);
    }] resume];
}

- (void)stopLoading {}
@end

// 诊断用：顶部弹条 3 秒，证明 dylib 真的加载了（仅 iOS，macOS 自测时跳过）
#if TARGET_OS_IPHONE
static void showBadge(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *host = UIApplication.sharedApplication.windows.firstObject;
        if (!host) return;
        CGFloat w = host.bounds.size.width;
        UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, w - 32, 40)];
        tip.text = @"喵神补丁 v4 已加载";
        tip.textAlignment = NSTextAlignmentCenter;
        tip.textColor = UIColor.whiteColor;
        tip.backgroundColor = [UIColor colorWithRed:0.9 green:0.05 blue:0.08 alpha:0.92];
        tip.font = [UIFont boldSystemFontOfSize:15];
        tip.layer.cornerRadius = 10;
        tip.clipsToBounds = YES;
        tip.alpha = 0;
        [host addSubview:tip];
        [UIView animateWithDuration:0.25 animations:^{ tip.alpha = 1; } completion:^(BOOL f) {
            [UIView animateWithDuration:0.4 delay:3.0 options:0 animations:^{ tip.alpha = 0; }
                             completion:^(BOOL g) { [tip removeFromSuperview]; }];
        }];
    });
}

__attribute__((constructor)) static void noad_init(void) {
    [NSURLProtocol registerClass:[NoadProtocol class]];
    NSLog(@"[noad] dylib loaded v4, NSURLProtocol registered");
#if TARGET_OS_IPHONE
    showBadge();
#endif
}
