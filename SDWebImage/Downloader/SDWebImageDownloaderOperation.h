/*
 SDWebImageDownloaderOperation提供了下载单张图片的能力
 
 继承于NSOpration，用来处理下载任务
 
 每张图片的下载都会发出一个异步的 HTTP 请求，这个请求就是由 SDWebImageDownloaderOperation 管理的。
 
         1.如何实现下载的网络请求？
 
         2.如何管理整个图片下载的过程？
 
         3.图片下载完成后需要做哪些处理？
 
 当被加入operationQueue中后，情况不同，operationQueue中所有的NSOperation都是异步执行的
 至于是串行还是并发，都由maxConcurrentOperationCount控制，当maxConcurrentOperationCount == 1时，相当于串行了。
 
 NSConnection 负责网络请求，
 NSOperation 负责多线程。
 
 
 SDWebImageDownloaderOperation是一个自定义、并行的NSOperation子类。这个子类主要实现的功能有：
 
 由于只自定义的并行NSOperation,所以需要管理executing,finished等各种属性的处理，并且手动触发KVO。
 在start(NSOperation规定，没有为什么)方法里面实现主要逻辑。
 在NSURLSessionTaskDelegate和NSURLSessionDataDelegate中处理数据的加载，以及进度Block的处理。
 如果unownedSession属性因为某种原因是nil，则手动初始化一个做网络请求。
 在代理方法中对认证、数据拼装、完成回调Block做处理。
 通过发送
 SDWebImageDownloadStopNotification,
 SDWebImageDownloadFinishNotification,
 SDWebImageDownloadReceiveResponseNotification,
 SDWebImageDownloadStartNotification
 来通知Operation的状态。
 
 
 NSOperation有两个方法：main() 和 start()。
 如果想使用同步，那么最简单方法的就是把逻辑写在main()中，
 使用异步，需要把逻辑写到start()中，然后加入到队列之中。
 
 NSOperation什么时候执行呢？按照正常想法，是手动调用main() 和 start()，当然这样也可以。
 当调用start()的时候，默认的是在当前线程执行同步操作，如果是在主线程调用了，那么必然会导致程序死锁。
 另外一种方法就是加入到operationQueue中，operationQueue会尽快执行NSOperation，如果operationQueue是同步的，那么它会等到NSOperation的isFinished等于YES后，再执行下一个任务，
 如果是异步的，通过设置maxConcurrentOperationCount来控制同时执行的最大操作，某个操作完成后，继续其他的操作。
 
 并不是调用了cancel就一定取消了，如果NSOperation没有执行，那么就会取消，如果执行了，只会将isCancelled设置为YES。
 所以，在我们的操作中，我们应该在每个操作开始前，或者在每个有意义的实际操作完成后，先检查下这个属性是不是已经设置为YES。如果是YES，则后面操作都可以不用再执行了。

 */

#import <Foundation/Foundation.h>
#import "SDWebImageDownloader.h"
#import "SDWebImageOperation.h"
/*
 SDWebImageDownloaderOperation有四种情况会发送通知：
 
 任务开始
 接收到数据
 暂停
 完成
 */
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadStartNotification;
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadReceiveResponseNotification;
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadStopNotification;
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadFinishNotification;

/**
 通过设置不同的枚举值告诉系统当前在进行什么样的工作，然后系统会通过合理的资源控制来最高效的执行任务代码，其中主要涉及到 CPU 调度的优先级、IO 优先级、任务运行在哪个线程以及运行的顺序等等，我们通过一个抽象的 Quality of Service 枚举值来表明服务质量的意图以及类别。
一个高质量的服务就意味着更多的资源得以提供来更快的完成操作。

它的每一个枚举值用以表示一个操作的性质和紧迫性。
应用程序选择最合适的值用以操作，以确保一个良好的用户体验。
 
 　　1.NSQualityOfServiceUserInteractive 与用户交互的任务，这些任务通常跟 UI 级别的刷新相关，比如动画，这些任务需要在一瞬间完成。
 
 　　2.NSQualityOfServiceUserInitiated 由用户发起的并且需要立即得到结果的任务，比如滑动 scrollView时去加载数据用于后续 cell 的显示，这些任务通常跟后续的用户交互相关，在几秒或者更短的时间内完成。
 
 　　3.NSQualityOfServiceUtility 用于表述执行一项工作后，用户并不需要立即得到结果。这一工作通常用户已经请求过或者在初始化的时候已经自动执行，不会阻碍用户用户的进一步交互，通常在用户可见的时间尺度和可能由一个非模态的进度指示器展示给用户。一些可能需要花点时间的任务，这些任务不需要马上返回结果，比如下载的任务，这些任务可能花费几秒或者几分钟的时间
 
 　　4.NSQualityOfServiceBackground 这些任务对用户不可见，比如后台进行备份的操作，这些任务可能需要较长的时间，几分钟甚至几个小时
 
 　　5.NSQualityOfServiceDefault 默认的QoS表明QoS信息缺失。尽可能的从其它资源推断可能的QoS信息。如果这一推断不成立，一个位于 NSQualityOfServiceUserInitiated 和 NSQualityOfServiceUtility 之间的 QoS 将得以使用。
 
 
  表示 NSOperation 状态的属性。NSOperation提供了 ready、cancelled、executing、finished 这几个状态变化，我们的开发也是必须处理自己关心的其中的状态。这些状态都是基于 keypath 的 KVO 通知决定，所以在你手动改变自己关心的状态时，请别忘了手动发送通知。这里面每个属性都是相互独立的，同时只可能有一个状态是 YES。 finished 这个状态在操作完成后请及时设置为 YES，因为 NSOperationQueue 所管理的队列中，只有 isFinished 为 YES 时才将其移除队列，这点在内存管理和避免死锁很关键。
 
 */

/**
 Describes a downloader operation. If one wants to use a custom downloader op, it needs to inherit from `NSOperation` and conform to this protocol
 如果我们想要实现一个自定义的下载操作，就必须继承自NSOperation,同时实现SDWebImageDownloaderOperationInterface这个协议，
 我们不去看其他的代码，只做一个简单的猜测:很可能在别的类中，只使用SDWebImageDownloaderOperationInterface和NSOperation中的方法和属性。
 
 
 */

@protocol SDWebImageDownloaderOperationInterface<NSObject>
//  初始化方法    使用NSURLRequest,NSURLSession和SDWebImageDownloaderOptions初始化
- (nonnull instancetype)initWithRequest:(nullable NSURLRequest *)request
                              inSession:(nullable NSURLSession *)session
                                options:(SDWebImageDownloaderOptions)options;
// 给Operation添加进度和回调Block
- (nullable id)addHandlersForProgress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                            completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock;

//是否需要解码
- (BOOL)shouldDecompressImages;
- (void)setShouldDecompressImages:(BOOL)value;


//设置是否需要设置凭证

- (nullable NSURLCredential *)credential;
- (void)setCredential:(nullable NSURLCredential *)value;

@end


@interface SDWebImageDownloaderOperation : NSOperation <SDWebImageDownloaderOperationInterface, SDWebImageOperation, NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

/**操作任务使用的请求
 * The request used by the operation's task.
 * 用来给 operation 中的 connection 使用的请求
 */
@property (strong, nonatomic, readonly, nullable) NSURLRequest *request;

/**操作任务
 * The operation's task
 */
@property (strong, nonatomic, readonly, nullable) NSURLSessionTask *dataTask;

//是否需要解码(来源于协议
@property (assign, nonatomic) BOOL shouldDecompressImages;

/**
 *  Was used to determine whether the URL connection should consult the credential storage for authenticating the connection.
 *  @deprecated Not used for a couple of versions
 */
@property (nonatomic, assign) BOOL shouldUseCredentialStorage __deprecated_msg("Property deprecated. Does nothing. Kept only for backwards compatibility");

/**  是否需要设置凭证
 * The credential used for authentication challenges in `-connection:didReceiveAuthenticationChallenge:`.
 *
 * This will be overridden by any shared credentials that exist for the username or password of the request URL, if present.
 */
@property (nonatomic, strong, nullable) NSURLCredential *credential;

/**
 * The SDWebImageDownloaderOptions for the receiver.
 */
@property (assign, nonatomic, readonly) SDWebImageDownloaderOptions options;

/**总大小
 * The expected size of data.
 */
@property (assign, nonatomic) NSInteger expectedSize;

/** 响应对象
 * The response returned by the operation's connection.
 */
@property (strong, nonatomic, nullable) NSURLResponse *response;

/**
 *  Initializes a `SDWebImageDownloaderOperation` object
 *
 *  @see SDWebImageDownloaderOperation
 *
 *  @param request        the URL request
 *  @param session        the URL session in which this operation will run
 *  @param options        downloader options
 *
 *  @return the initialized instance
 */
- (nonnull instancetype)initWithRequest:(nullable NSURLRequest *)request
                              inSession:(nullable NSURLSession *)session
                                options:(SDWebImageDownloaderOptions)options NS_DESIGNATED_INITIALIZER;

/**
 *  Adds handlers for progress and completion. Returns a tokent that can be passed to -cancel: to cancel this set of
 *  callbacks.
 *
 *  @param progressBlock  the block executed when a new chunk of data arrives.
 *                        @note the progress block is executed on a background queue
 *  @param completedBlock the block executed when the download is done.
 *                        @note the completed block is executed on the main queue for success. If errors are found, there is a chance the block will be executed on a background queue
 *
 *  @return the token to use to cancel this set of handlers
 */
- (nullable id)addHandlersForProgress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                            completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock;

/**
 *  Cancels a set of callbacks. Once all callbacks are canceled, the operation is cancelled.
 *
 *  @param token the token representing a set of callbacks to cancel
 *
 *  @return YES if the operation was stopped because this was the last token to be canceled. NO otherwise.
 */
- (BOOL)cancel:(nullable id)token;

@end
