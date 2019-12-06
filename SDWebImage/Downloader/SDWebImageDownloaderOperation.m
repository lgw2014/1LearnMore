/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloaderOperation.h"
#import "SDWebImageManager.h"
#import "NSImage+WebCache.h"
#import "SDWebImageCodersManager.h"
/**
 
 我们的目的是下载一张图片，那么我们最核心的逻辑是什么呢？
 
 初始化一个task
 添加响应者
 开启下载任务
 处理下载过程和结束后的事情
 */
NSString *const SDWebImageDownloadStartNotification = @"SDWebImageDownloadStartNotification";
NSString *const SDWebImageDownloadReceiveResponseNotification = @"SDWebImageDownloadReceiveResponseNotification";
NSString *const SDWebImageDownloadStopNotification = @"SDWebImageDownloadStopNotification";
NSString *const SDWebImageDownloadFinishNotification = @"SDWebImageDownloadFinishNotification";

static NSString *const kProgressCallbackKey = @"progress";
static NSString *const kCompletedCallbackKey = @"completed";

typedef NSMutableDictionary<NSString *, id> SDCallbacksDictionary;

@interface SDWebImageDownloaderOperation ()

@property (strong, nonatomic, nonnull) NSMutableArray<SDCallbacksDictionary *> *callbackBlocks;
/**
 _callbackBlocks数组中存放的是SDCallbacksDictionary类型的数据，
 那么这个SDCallbacksDictionary其实就是一个字典，key是一个字符串，
 这个字符串有两种情况:kProgressCallbackKey和kCompletedCallbackKey,
 也就是说进度和完成的回调都是放到一个数组中的。那么字典的值就是回调的block了。
 
 responseFromCached 用于设置是否需要缓存响应，默认为YES
 */


/**
  自定义并行Operation需要管理的两个属性。默认是readonly的，我们这里通过声明改为可修改的。方便我们在后面操作。
  */
@property (assign, nonatomic, getter = isExecuting) BOOL executing;
@property (assign, nonatomic, getter = isFinished) BOOL finished;
/**
 存储图片数据
 */
@property (strong, nonatomic, nullable) NSMutableData *imageData;
@property (copy, nonatomic, nullable) NSData *cachedData;
/**
 通过SDWebImageDownloader传过来。所以这里是weak。因为他是通过SDWebImageDownloader管理的。
 */


//unownedSession这个属性是我们初始化时候传进来的参数，作者提到。这个参数不一定是可用的。也就是说是不安全的。
//当出现不可用的情况的时候，就需要使用ownedSession;
//This is weak because it is injected by whoever manages this session. If this gets nil-ed out, we won't be able to run
// the task associated with this operation
@property (weak, nonatomic, nullable) NSURLSession *unownedSession;
// This is set if we're using not using an injected NSURLSession. We're responsible of invalidating this one
/**
 如果unownedSession是nil，我们需要手动创建一个并且管理他的生命周期和代理方法
 */
@property (strong, nonatomic, nullable) NSURLSession *ownedSession;
/**
 dataTask对象
 */
@property (strong, nonatomic, readwrite, nullable) NSURLSessionTask *dataTask;
/**
 一个并行queue。用于控制数据的处理
 barrierQueue 是一个 GCD 队列
 */
@property (strong, nonatomic, nullable) dispatch_queue_t barrierQueue;
/**
 如果用户设置了后台继续加载选线。则通过backgroundTask来继续下载图片
 backgroundTaskId 是在 app 进入后台后申请的后台任务的身份。
 */
#if SD_UIKIT
@property (assign, nonatomic) UIBackgroundTaskIdentifier backgroundTaskId;
#endif

@property (strong, nonatomic, nullable) id<SDWebImageProgressiveCoder> progressiveCoder;

@end

@implementation SDWebImageDownloaderOperation


// 覆盖了父类的属性，需要重新实现属性合成方法
@synthesize executing = _executing;
@synthesize finished = _finished;

- (nonnull instancetype)init {
    return [self initWithRequest:nil inSession:nil options:0];
}

- (nonnull instancetype)initWithRequest:(nullable NSURLRequest *)request
                              inSession:(nullable NSURLSession *)session
                                options:(SDWebImageDownloaderOptions)options {
    if ((self = [super init])) {
        _request = [request copy];
        _shouldDecompressImages = YES;
        _options = options;
        _callbackBlocks = [NSMutableArray new];
        _executing = NO;
        _finished = NO;
        _expectedSize = 0;
        _unownedSession = session;
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderOperationBarrierQueue", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}
/*
 添加响应者
 就是把字典添加到数组中去，
 我们可以创建两种类型的队列，串行和并行，也就是DISPATCH_QUEUE_SERIAL,DISPATCH_QUEUE_CONCURRENT。
 那么dispatch_barrier_async和dispatch_barrier_sync究竟有什么不同之处呢？
 
 barrier这个词是栅栏的意思，也就是说是用来做拦截功能的，上边的这另种都能够拦截任务，换句话说，就是只有我的任务完成后，队列后边的任务才能完成。
 
 dispatch_barrier_sync控制了任务往队列添加这一过程，只有当我的任务完成之后，才能往队列中添加任务。
 dispatch_barrier_async不会控制队列添加任务。但是只有当我的任务完成后，队列中后边的任务才会执行。
 
 那么在这里的任务是往数组中添加数据，对顺序没什么要求，我们采取dispatch_barrier_async就可以了，已经能保证数据添加的安全性了。
 
 */
- (nullable id)addHandlersForProgress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                            completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock {
  
    SDCallbacksDictionary *callbacks = [NSMutableDictionary new];
    //把Operation对应的回调和进度Block存入一个字典中
    if (progressBlock) callbacks[kProgressCallbackKey] = [progressBlock copy];
    if (completedBlock) callbacks[kCompletedCallbackKey] = [completedBlock copy];
  
    //把完成和进度Block加入callbackBlocks中
    dispatch_barrier_async(self.barrierQueue, ^{
        [self.callbackBlocks addObject:callbacks];
    });
    return callbacks;
}


//这个方法是根据key取出所有符合key的block，这里采用了同步的方式，相当于加锁。
/*
 比较有意思的是[self.callbackBlocks valueForKey:key]这段代码，self.callbackBlocks是一个数组，我们假定他的结构是这样的：
 
 @[@{@"completed" : Block1},
 @{@"progress" : Block2},
 @{@"completed" : Block3},
 @{@"progress" : Block4},
 @{@"completed" : Block5},
 @{@"progress" : Block6}]
 调用[self.callbackBlocks valueForKey:@"progress"]后会得到[Block2, Block4, Block6].
 removeObjectIdenticalTo:这个方法会移除数组中指定相同地址的元素。
*/
- (nullable NSArray<id> *)callbacksForKey:(NSString *)key {
    __block NSMutableArray<id> *callbacks = nil;
    dispatch_sync(self.barrierQueue, ^{
        // We need to remove [NSNull null] because there might not always be a progress block for each callback
        callbacks = [[self.callbackBlocks valueForKey:key] mutableCopy];
        //　移除 callbacks 里面的 [NSNull null]。
        [callbacks removeObjectIdenticalTo:[NSNull null]];
    });
    return [callbacks copy];    // strip mutability here
}


//这个函数，就是取消某一回调。
//使用了dispatch_barrier_sync，保证，必须该队列之前的任务都完成，且该取消任务结束后，在将其他的任务加入队列。
//在 self.barrierQueue 同步删除 self.callbackBlocks 里面的指定回调
//当 self.callbackBlocks 里面的回调删除完的时候，取消操作。
- (BOOL)cancel:(nullable id)token {
    __block BOOL shouldCancel = NO;
    dispatch_barrier_sync(self.barrierQueue, ^{
        [self.callbackBlocks removeObjectIdenticalTo:token];
        if (self.callbackBlocks.count == 0) {
            shouldCancel = YES;
        }
    });
    if (shouldCancel) {
        [self cancel];
    }
    return shouldCancel;
}



// 并行的Operation需要重写这个方法，在这个方法里面做具体的处理

//开启下载任务

//首先创建了用来下载图片数据的 NSURLConnection，然后开启 connection，
//同时发出开始图片下载的 SDWebImageDownloadStartNotification 通知，
//为了防止非主线程的请求被 kill 掉，这里开启 runloop 保活，直到请求返回。
- (void)start {
//给 `self` 加锁
//如果 `self` 被 cancell 掉的话，finished 属性变为 YES，reset 下载数据和回调 block，然后直接 return。
    
    @synchronized (self) {
        if (self.isCancelled) {
            self.finished = YES;
            [self reset];
            return;
        }

#if SD_UIKIT
//如果允许程序退到后台后继续下载，就标记为允许后台执行，在后台任务过期的回调 block 中
//        首先来一个 weak-strong dance
//        调用 cancel 方法（这个方法里面又做了一些处理，反正就是 cancel 掉当前的 operation）
//        调用 UIApplication 的 endBackgroundTask： 方法结束任务
//        记录结束后的 taskId
        Class UIApplicationClass = NSClassFromString(@"UIApplication");
        BOOL hasApplication = UIApplicationClass && [UIApplicationClass respondsToSelector:@selector(sharedApplication)];
        
        //如果用户设置了Background模式，则设置一个backgroundTask
        if (hasApplication && [self shouldContinueWhenAppEntersBackground]) {
            __weak __typeof__ (self) wself = self;
            UIApplication * app = [UIApplicationClass performSelector:@selector(sharedApplication)];
            self.backgroundTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
                //background结束以后。做清理工作
                __strong __typeof (wself) sself = wself;
                //background结束以后，做清理工作

                if (sself) {
                    [sself cancel];

                    [app endBackgroundTask:sself.backgroundTaskId];
                    sself.backgroundTaskId = UIBackgroundTaskInvalid;
                }
            }];
        }
#endif

        if (self.options & SDWebImageDownloaderIgnoreCachedResponse) {
            // Grab the cached data for later check
            NSCachedURLResponse *cachedResponse = [[NSURLCache sharedURLCache] cachedResponseForRequest:self.request];
            if (cachedResponse) {
                self.cachedData = cachedResponse.data;
            }
        }
//# 启动 connection
//# 因为上面初始化 connection 时可能会失败，所以这里我们需要根据不同情况做处理
//## A.如果 connection 不为 nil
//### 回调 progressBlock（初始的 receivedSize 为 0，expectSize 为 -1）
//### 发出 SDWebImageDownloadStartNotification 通知（SDWebImageDownloader 会监听到）
//### 开启 runloop
//### runloop 结束后继续往下执行（也就是 cancel 掉或者 NSURLConnection 请求完毕代理回调后调用了 CFRunLoopStop）
//
//## B.如果 connection 为 nil，回调 completedBlock，返回 connection 初始化失败的错误信息
        
        
        NSURLSession *session = self.unownedSession;
        //如果SDWebImageDownloader传入的session是nil，则自己手动初始化一个。

        if (!self.unownedSession) {
            NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
            sessionConfig.timeoutIntervalForRequest = 15;
            
            /**
             *  Create the session for this task
             *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
             *  method calls and completion handler calls.
             */
            self.ownedSession = [NSURLSession sessionWithConfiguration:sessionConfig
                                                              delegate:self
                                                         delegateQueue:nil];
            session = self.ownedSession;
        }
        
        self.dataTask = [session dataTaskWithRequest:self.request];
        self.executing = YES;
    }
    //发送请求
    [self.dataTask resume];

    if (self.dataTask) {
        //第一次调用进度BLOCK
        for (SDWebImageDownloaderProgressBlock progressBlock in [self callbacksForKey:kProgressCallbackKey]) {
            progressBlock(0, NSURLResponseUnknownLength, self.request.URL);
        }
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStartNotification object:weakSelf];
        });
    } else {
        [self callCompletionBlocksWithError:[NSError errorWithDomain:NSURLErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Connection can't be initialized"}]];
    }

#if SD_UIKIT
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    
    //# 下载完成后，调用 endBackgroundTask: 标记后台任务结束

    if (self.backgroundTaskId != UIBackgroundTaskInvalid) {
        UIApplication * app = [UIApplication performSelector:@selector(sharedApplication)];
        [app endBackgroundTask:self.backgroundTaskId];
        self.backgroundTaskId = UIBackgroundTaskInvalid;
    }
#endif
}

// 如果要取消一个Operation，就会调用这个方法。

- (void)cancel {
    @synchronized (self) {
        [self cancelInternal];
    }
}

- (void)cancelInternal {
    if (self.isFinished) return;
    [super cancel];

    if (self.dataTask) {
        [self.dataTask cancel];
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:weakSelf];
        });
        //更新状态

        // As we cancelled the connection, its callback won't be called and thus won't
        // maintain the isFinished and isExecuting flags.
        if (self.isExecuting) self.executing = NO;
        if (!self.isFinished) self.finished = YES;
    }

    [self reset];
}
/**
 下载完成
 */
- (void)done {
    self.finished = YES;
    self.executing = NO;
    [self reset];
}
/**
 如果任务已经被设置为取消了，那么就无需开启下载任务了，并进行重置
 */
- (void)reset {
    __weak typeof(self) weakSelf = self;
    dispatch_barrier_async(self.barrierQueue, ^{
        [weakSelf.callbackBlocks removeAllObjects];
    });
    self.dataTask = nil;
    
    NSOperationQueue *delegateQueue;
    if (self.unownedSession) {
        delegateQueue = self.unownedSession.delegateQueue;
    } else {
        delegateQueue = self.ownedSession.delegateQueue;
    }
    if (delegateQueue) {
        NSAssert(delegateQueue.maxConcurrentOperationCount == 1, @"NSURLSession delegate queue should be a serial queue");
        [delegateQueue addOperationWithBlock:^{
            weakSelf.imageData = nil;
        }];
    }
    
    if (self.ownedSession) {
        [self.ownedSession invalidateAndCancel];
        self.ownedSession = nil;
    }
}

// 需要手动触发_finished的KVO。这个是自定义并发`NSOperation`必须实现的。
- (void)setFinished:(BOOL)finished {
    [self willChangeValueForKey:@"isFinished"];
    _finished = finished;
    [self didChangeValueForKey:@"isFinished"];
}
// 需要手动触发_executing的KVO。这个是自定义并发`NSOperation`必须实现的。
- (void)setExecuting:(BOOL)executing {
    [self willChangeValueForKey:@"isExecuting"];
    _executing = executing;
    [self didChangeValueForKey:@"isExecuting"];
}

// 返回YES，表明这个NSOperation对象是并发的

- (BOOL)isConcurrent {
    return YES;
}

#pragma mark NSURLSessionDataDelegate

/**
 *  下载过程中的 response 回调，调用一次
 */
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    
    //'304 Not Modified' is an exceptional one
    //当收到响应的时候执行的代理方法。当没有收到响应码或者响应码小于 400 且响应码不是 304 的时候，认定为正常的响应。
    //304 比较特殊，当响应码是 304 的时候，表示这个响应没有变化，可以在缓存中读取。响应码是其它的情况的时候就表示为错误的请求。
    if (![response respondsToSelector:@selector(statusCode)] || (((NSHTTPURLResponse *)response).statusCode < 400 && ((NSHTTPURLResponse *)response).statusCode != 304)) {
        
        
        //当响应正常的时候，给 self.expectedSize 赋值，
        //期望的总长度
        NSInteger expected = (NSInteger)response.expectedContentLength;
        expected = expected > 0 ? expected : 0;
        self.expectedSize = expected;
        //进度回调Block   执行 self.callbackBlocks 里面表示进度的回调 block，
        for (SDWebImageDownloaderProgressBlock progressBlock in [self callbacksForKey:kProgressCallbackKey]) {
            progressBlock(0, expected, self.request.URL);
        }
        
        //给 self.imageData 根据 expectedSize 的大小初始化，
        self.imageData = [[NSMutableData alloc] initWithCapacity:expected];
        //把 response  赋值给 self.response
        self.response = response;
        __weak typeof(self) weakSelf = self;
        //异步调取主线程发送 SDWebImageDownloadReceiveResponseNotification 通知。
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadReceiveResponseNotification object:weakSelf];
        });
    } else {
        NSUInteger code = ((NSHTTPURLResponse *)response).statusCode;
        
        
        //当以上情况都排除，响应不正常的时候，如果服务器返回的响应码是 "304未修改" 的情况，表示远程图像没有改变，
        //对于 304 的情况只需要取消操作，并从缓存返回缓存的图像。
        //This is the case when server returns '304 Not Modified'. It means that remote image is not changed.
        //In case of 304 we need just cancel the operation and return cached image from the cache.
        //如果返回304表示图片么有变化。在这种情况下，我们只需要取消operation并且返回缓存的图片就可以了。
        if (code == 304) {
            [self cancelInternal];
        } else {
            [self.dataTask cancel];
        }
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:weakSelf];
        });
        //调用 callCompletionBlocksWithError: 方法，携带错误信息回调。
        [self callCompletionBlocksWithError:[NSError errorWithDomain:NSURLErrorDomain code:((NSHTTPURLResponse *)response).statusCode userInfo:nil]];

        [self done];
    }
    
    //这个表示允许继续加载
    if (completionHandler) {
        completionHandler(NSURLSessionResponseAllow);
    }
}

/**
 下载过程中 data 回调，调用多次
 更新进度、拼接图片数据
 */
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.imageData appendData:data];

    if ((self.options & SDWebImageDownloaderProgressiveDownload) && self.expectedSize > 0) {
        // Get the image data
        NSData *imageData = [self.imageData copy];
        // Get the total bytes downloaded
        //获取已经下载的数据长度
        const NSInteger totalSize = imageData.length;
        // Get the finish status
        BOOL finished = (totalSize >= self.expectedSize);
        
        if (!self.progressiveCoder) {
            // We need to create a new instance for progressive decoding to avoid conflicts
            for (id<SDWebImageCoder>coder in [SDWebImageCodersManager sharedInstance].coders) {
                if ([coder conformsToProtocol:@protocol(SDWebImageProgressiveCoder)] &&
                    [((id<SDWebImageProgressiveCoder>)coder) canIncrementallyDecodeFromData:imageData]) {
                    self.progressiveCoder = [[[coder class] alloc] init];
                    break;
                }
            }
        }
        
        UIImage *image = [self.progressiveCoder incrementallyDecodedImageWithData:imageData finished:finished];
        if (image) {
            NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:self.request.URL];
            image = [self scaledImageForKey:key image:image];
            if (self.shouldDecompressImages) {
                image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&data options:@{SDWebImageCoderScaleDownLargeImagesKey: @(NO)}];
            }
            
            [self callCompletionBlocksWithImage:image imageData:nil error:nil finished:NO];
        }
    }

    for (SDWebImageDownloaderProgressBlock progressBlock in [self callbacksForKey:kProgressCallbackKey]) {
        progressBlock(self.imageData.length, self.expectedSize, self.request.URL);
    }
}




//用于响应缓存设置，如果把回调的参数设置为nil，那么就不会缓存响应

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {
    //根据request的选项。决定是否缓存NSCachedURLResponse

    NSCachedURLResponse *cachedResponse = proposedResponse;

    if (self.request.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData) {
        // Prevents caching of responses
        cachedResponse = nil;
    }
    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}

#pragma mark NSURLSessionTaskDelegate
// 网络请求加载完成，在这里处理获得的数据

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    @synchronized(self) {
        self.dataTask = nil;
        __weak typeof(self) weakSelf = self;
        //发送图片下载完成的通知

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:weakSelf];
            if (!error) {
                [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadFinishNotification object:weakSelf];
            }
        });
    }
    
    if (error) {
        [self callCompletionBlocksWithError:error];
    } else {
        if ([self callbacksForKey:kCompletedCallbackKey].count > 0) {
            /**
             *  If you specified to use `NSURLCache`, then the response you get here is what you need.
             */
            NSData *imageData = [self.imageData copy];
            if (imageData) {
                /**  if you specified to only use cached data via `SDWebImageDownloaderIgnoreCachedResponse`,
                 *  then we should check if the cached data is equal to image data
                 */
                if (self.options & SDWebImageDownloaderIgnoreCachedResponse && [self.cachedData isEqualToData:imageData]) {
                    // call completion block with nil
                    [self callCompletionBlocksWithImage:nil imageData:nil error:nil finished:YES];
                } else {
                    UIImage *image = [[SDWebImageCodersManager sharedInstance] decodedImageWithData:imageData];
                    //获取url对应的缓存Key
                    NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:self.request.URL];
                    image = [self scaledImageForKey:key image:image];
                    
                    BOOL shouldDecode = YES;
                    // Do not force decoding animated GIFs and WebPs
                    if (image.images) {
                        shouldDecode = NO;
                    } else {
#ifdef SD_WEBP
                        SDImageFormat imageFormat = [NSData sd_imageFormatForImageData:imageData];
                        if (imageFormat == SDImageFormatWebP) {
                            shouldDecode = NO;
                        }
#endif
                    }
                    
                    if (shouldDecode) {
                        //是否解码图片数据

                        if (self.shouldDecompressImages) {
                            BOOL shouldScaleDown = self.options & SDWebImageDownloaderScaleDownLargeImages;
                            image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&imageData options:@{SDWebImageCoderScaleDownLargeImagesKey: @(shouldScaleDown)}];
                        }
                    }
                    if (CGSizeEqualToSize(image.size, CGSizeZero)) {
                        [self callCompletionBlocksWithError:[NSError errorWithDomain:SDWebImageErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Downloaded image has 0 pixels"}]];
                    } else {
                        [self callCompletionBlocksWithImage:image imageData:imageData error:nil finished:YES];
                    }
                }
            } else {
                [self callCompletionBlocksWithError:[NSError errorWithDomain:SDWebImageErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Image data is nil"}]];
            }
        }
    }
    [self done];
}
/*
 验证HTTPS的证书
 */

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;
    //使用可信任证书机构的证书
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        //如果SDWebImageDownloaderAllowInvalidSSLCertificates属性设置了，则不验证SSL证书。直接信任

        if (!(self.options & SDWebImageDownloaderAllowInvalidSSLCertificates)) {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        } else {
            credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            disposition = NSURLSessionAuthChallengeUseCredential;
        }
    } else {
        //使用自己生成的证书

        if (challenge.previousFailureCount == 0) {
            if (self.credential) {
                credential = self.credential;
                disposition = NSURLSessionAuthChallengeUseCredential;
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
        }
    }
    
    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

#pragma mark Helper methods
/**
 * 通过image对象获取对应scale模式下的图像
 */
- (nullable UIImage *)scaledImageForKey:(nullable NSString *)key image:(nullable UIImage *)image {
    return SDScaledImageForKey(key, image);
}



/**
 　　判断 self.options （下载设置）是否在 app 进入后台后继续未完成的下载（如果后台任务过期，操作将被取消）：
 */
- (BOOL)shouldContinueWhenAppEntersBackground {
    return self.options & SDWebImageDownloaderContinueInBackground;
}

- (void)callCompletionBlocksWithError:(nullable NSError *)error {
    [self callCompletionBlocksWithImage:nil imageData:nil error:error finished:YES];
}
/**
 处理回调
 
 @param image UIImage数据
 @param imageData Image的data数据
 @param error 错误
 @param finished 是否完成的标记位
 */
- (void)callCompletionBlocksWithImage:(nullable UIImage *)image
                            imageData:(nullable NSData *)imageData
                                error:(nullable NSError *)error
                             finished:(BOOL)finished {
    //获取key对应的回调Block数组

    NSArray<id> *completionBlocks = [self callbacksForKey:kCompletedCallbackKey];
    //调用回调

    dispatch_main_async_safe(^{
        for (SDWebImageDownloaderCompletedBlock completedBlock in completionBlocks) {
            completedBlock(image, imageData, error, finished);
        }
    });
}

@end
