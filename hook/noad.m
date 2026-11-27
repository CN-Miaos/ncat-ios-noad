// 网飞猫 iOS 补丁 — v5
// 换思路：截图显示首页是 kekys.com 的 H5 页面（域名、宫格、轮播全是网页），
// 所以光改 JSON 不生效。这一版同时处理：
//   · HTML 响应 → 注入一段 JS，直接删成人/博彩宫格卡片、把轮播图换成我们的图
//   · JSON 响应 → 原有过滤（成人条目 / 广告字段 / banner / 资料卡）
//   · /config/uniq* → 空壳（开屏/暂停广告位）
//   · 启动 2 秒后在顶部弹条 3 秒「喵神补丁 v5 已加载」——肉眼确认钩子有没有被加载
//   · 每个响应打一行日志（URL / 长度 / MIME / 前 80 字节），便于真机定位
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

// 注入到 H5 页面里的脚本（JS 内部只用单引号，避免和 ObjC 字符串打架）
static NSString *injectJS(void) {
    static NSString *js; static dispatch_once_t o;
    dispatch_once(&o, ^{
        js = [NSString stringWithFormat:@"(function(){"
             @"var K=['成人','福利','伦理','18禁','里番','无码','三级','情色','午夜','黄剧','黄片','裸','博彩','棋牌','开元','外围','外围女','AV连续剧'];"
             @"var B='%@';"
             @"function bad(t){if(!t)return false;for(var i=0;i<K.length;i++){if(t.indexOf(K[i])>=0)return true;}return false;}"
             @"function sweep(){try{"
             @"document.querySelectorAll('img').forEach(function(im){"
             @"var box=im.closest('a,div,li')||im.parentElement;"
             @"var t=((box&&box.innerText)||'')+' '+(im.alt||'');"
             @"if(bad(t)){im.src=B;im.removeAttribute('srcset');}});"
             @"var n=document.querySelectorAll('a,div,li,span,p,strong,b');"
             @"for(var i=n.length-1;i>=0;i--){var e=n[i],t=(e.innerText||'').trim();"
             @"if(!t||t.length>30)continue;if(!bad(t))continue;"
             @"if(e.querySelector('img'))continue;if(e.children.length>3)continue;e.remove();}"
             @"}catch(err){}}"
             @"window.addEventListener('load',function(){sweep();setTimeout(sweep,1200);setTimeout(sweep,3000);"
             @"try{new MutationObserver(sweep).observe(document.body,{childList:true,subtree:true});}catch(e){}});"
             @"})();", kBannerURL];
    });
    return js;
}

static NSArray<NSString *> *adultWords(void) {
    static NSArray *w; static dispatch_once_t o;
    dispatch_once(&o, ^{ w = @[ @"成人", @"福利", @"伦理", @"18禁", @"里番", @"无码", @"三级", @"情色", @"午夜",
                                @"黄剧", @"黄片", @"裸", @"博彩", @"棋牌", @"开元", @"外围", @"AV连续剧" ]; });
    return w;
}
static NSArray<NSString *> *dropKeys(void) {
    static NSArray *k; static dispatch_once_t o;
    dispatch_once(&o, ^{ k = @[ @"bannerAD", @"startAD", @"pauseAD", @"adList", @"adInfo", @"ads",
                                @"ad", @"adUnit", @"adUnits", @"adSource", @"adSwitch", @"adConfig" ]; });
    return k;
}
static NSArray<NSString *> *titleKeys(void) { return @[ @"vod_name", @"vodName", @"name", @"title", @"vod_title" ]; }
static NSArray<NSString *> *imageKeys(void) { return @[ @"image", @"img", @"pic", @"cover", @"vod_pic", @"vodPic" ]; }

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
static BOOL hasTitle(NSDictionary *item) { for (NSString *k in titleKeys()) if (item[k]) return YES; return NO; }

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

static NSData *scrubJSON(NSData *data) {
    if (!data.length) return data;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL];
    if (!json) return data;
    id clean = scrub(json);
    NSData *out = [NSJSONSerialization dataWithJSONObject:clean options:0 error:NULL];
    return out.length ? out : data;
}

// 往 HTML 末尾插脚本
static NSData *injectHTML(NSData *data) {
    if (!data.length) return data;
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!html.length) return data;
    NSString *tag = [NSString stringWithFormat:@"<script>%@</script>", injectJS()];
    NSRange r = [html rangeOfString:@"</body>" options:NSCaseInsensitiveSearch | NSBackwardsSearch];
    if (r.location == NSNotFound) {
        html = [html stringByAppendingString:tag];
    } else {
        html = [html stringByReplacingCharactersInRange:r withString:[tag stringByAppendingString:@"</body>"]];
    }
    NSData *out = [html dataUsingEncoding:NSUTF8StringEncoding];
    return out.length ? out : data;
}

@interface NoadProtocol : NSURLProtocol
@end

@implementation NoadProtocol

static BOOL isMedia(NSString *p) {
    static NSArray *ext;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ ext = @[ @".m3u8", @".ts", @".mp4", @".m4s", @".key", @".jpg", @".jpeg",
                                  @".png", @".webp", @".gif", @".svg", @".mp3", @".aac", @".vtt", @".css", @".woff", @".ttf" ]; });
    NSString *low = p.lowercaseString;
    for (NSString *e in ext) if ([low hasSuffix:e]) return YES;
    return NO;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:kHandled inRequest:request]) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    if (isMedia(request.URL.path ?: @"")) return NO;      // 媒体直通，不做二次代理
    return YES;
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

        NSString *mime = resp.MIMEType ?: @"";
        NSData *out = data;
        if ([mime rangeOfString:@"html"].location != NSNotFound) {
            out = injectHTML(data);
            NSLog(@"[noad] HTML %@ %lu→%lu", path, (unsigned long)data.length, (unsigned long)out.length);
        } else if ([mime rangeOfString:@"json"].location != NSNotFound) {
            out = scrubJSON(data);
            NSLog(@"[noad] JSON %@ %lu→%lu", path, (unsigned long)data.length, (unsigned long)out.length);
        } else {
            NSString *head = @"";
            if (data.length) {
                NSUInteger n = MIN(data.length, (NSUInteger)80);
                head = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, n)] encoding:NSUTF8StringEncoding] ?: @"<binary>";
            }
            NSLog(@"[noad] PASS %@ mime=%@ len=%lu head=%@", path, mime, (unsigned long)data.length, head);
        }

        NSHTTPURLResponse *hr = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        NSMutableDictionary *h = [hr.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
        [h removeObjectForKey:@"Content-Encoding"];
        h[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)out.length];
        NSHTTPURLResponse *fixed = [[NSHTTPURLResponse alloc]
            initWithURL:req.URL statusCode:hr ? hr.statusCode : 200 HTTPVersion:@"HTTP/1.1" headerFields:h];
        [self.client URLProtocol:self didReceiveResponse:fixed cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:out ?: [NSData data]];
        [self.client URLProtocolDidFinishLoading:self];
    }] resume];
}

- (void)stopLoading {}
@end

#if TARGET_OS_IPHONE
static void showBadge(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *host = UIApplication.sharedApplication.windows.firstObject;
        if (!host) return;
        CGFloat w = host.bounds.size.width;
        UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, w - 32, 40)];
        tip.text = @"喵神补丁 v5 已加载";
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
#endif

__attribute__((constructor)) static void noad_init(void) {
    [NSURLProtocol registerClass:[NoadProtocol class]];
    NSLog(@"[noad] dylib loaded v5, NSURLProtocol registered");
#if TARGET_OS_IPHONE
    showBadge();
#endif
}
