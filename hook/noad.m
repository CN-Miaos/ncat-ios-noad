// 网飞猫 iOS 去广告 / 去不良信息 / 品牌化 hook — v3
// 拦截：*.capi 与 /user/* 请求
//   1) /config/uniq*   → 空壳（开屏 / 暂停 / 信息流广告位全失效）
//   2) 数据接口 → 明文 JSON 时：
//        · 丢成人条目（isAdult / 标题或分类命中成人词）
//        · 删 bannerAD / startAD / pauseAD / adList 等广告字段
//        · banner 轮播改图
//   3) /user/* 与其它 → 放行；若 JSON 里带 nickname/avatar/signature 就改成本地品牌值
// 容错原则：解不出 JSON / 结构不认识 → 原样返回，绝不让 App 解码失败。
#import <Foundation/Foundation.h>

static NSString *const kBannerURL =
    @"https://cdn.jsdelivr.net/gh/CN-Miaos/Miaos.github.io@master/ncat/banner.jpg";
static NSString *const kAvatarURL =
    @"https://cdn.jsdelivr.net/gh/CN-Miaos/Miaos.github.io@master/ncat/avatar.png";
static NSString *const kNickname = @"Miaos喵神";
static NSString *const kSignature = @"永久SVIP · 做点好东西";
static NSString *const kHandled = @"NoadHandledKey";

static NSArray<NSString *> *adultWords(void) {
    static NSArray *w; static dispatch_once_t o;
    dispatch_once(&o, ^{ w = @[ @"成人", @"福利", @"伦理", @"18禁", @"里番", @"无码", @"三级", @"情色", @"午夜" ]; });
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

// 用户资料：只有「同时带 nickname 和 avatar/signature」的对象才认作资料卡，避免误伤签名字段
static void spoofProfile(NSMutableDictionary *d) {
    BOOL hasNick = [d[@"nickname"] isKindOfClass:[NSString class]] || [d[@"user_nickname"] isKindOfClass:[NSString class]];
    BOOL hasAva  = [d[@"avatar"] isKindOfClass:[NSString class]] || [d[@"user_avatar"] isKindOfClass:[NSString class]];
    BOOL hasSig  = [d[@"signature"] isKindOfClass:[NSString class]];
    if (!hasNick && !hasAva) return;
    for (NSString *k in @[ @"nickname", @"user_nickname" ])
        if (d[k]) d[k] = kNickname;
    for (NSString *k in @[ @"avatar", @"user_avatar" ])
        if (d[k]) d[k] = kAvatarURL;
    if (hasNick && hasSig) {
        for (NSString *k in @[ @"signature", @"signatureText", @"intro" ])
            if (d[k]) d[k] = kSignature;
    }
}

static id scrub(id obj) {
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id e in (NSArray *)obj) {
            if ([e isKindOfClass:[NSDictionary class]]) {
                NSDictionary *d = (NSDictionary *)e;
                if (hasTitle(d) && looksAdult(d)) continue;
                [out addObject:scrub(d)];
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

static NSData *scrubJSON(NSData *data) {
    if (!data.length) return data;
    id json = [NSJSONSerialization JSONObjectWithData:data
                                              options:NSJSONReadingMutableContainers error:NULL];
    if (!json) return data;
    id clean = scrub(json);
    NSData *out = [NSJSONSerialization dataWithJSONObject:clean options:0 error:NULL];
    return out.length ? out : data;
}

@interface NoadProtocol : NSURLProtocol
@end

@implementation NoadProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *u = request.URL.absoluteString ?: @"";
    if ([NSURLProtocol propertyForKey:kHandled inRequest:request]) return NO;
    if ([u rangeOfString:@".capi"].location != NSNotFound) return YES;
    NSString *p = request.URL.path ?: @"";
    if ([p hasPrefix:@"/user"]) return YES;      // 账号/资料接口
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
        NSLog(@"[noad] blocked %@", path);
        return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.protocolClasses = @[];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { [self.client URLProtocol:self didFailWithError:err]; return; }

        NSData *out = scrubJSON(data);

        NSHTTPURLResponse *hr = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        NSMutableDictionary *h = [hr.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
        [h removeObjectForKey:@"Content-Encoding"];
        h[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)out.length];
        NSHTTPURLResponse *fixed = [[NSHTTPURLResponse alloc]
            initWithURL:req.URL statusCode:hr ? hr.statusCode : 200
            HTTPVersion:@"HTTP/1.1" headerFields:h];
        [self.client URLProtocol:self didReceiveResponse:fixed cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:out ?: [NSData data]];
        [self.client URLProtocolDidFinishLoading:self];

        NSString *head = @"<binary>";
        if (data.length) {
            NSUInteger n = MIN(data.length, (NSUInteger)120);
            NSString *s = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, n)]
                                                encoding:NSUTF8StringEncoding];
            if (s) head = s;
        }
        NSLog(@"[noad] pass %@ %lu→%lu head=%@", path,
              (unsigned long)(data ? data.length : 0), (unsigned long)out.length, head);
    }] resume];
}

- (void)stopLoading {}

@end

__attribute__((constructor)) static void noad_init(void) {
    [NSURLProtocol registerClass:[NoadProtocol class]];
    NSLog(@"[noad] dylib loaded v3, NSURLProtocol registered");
}
