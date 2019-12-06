/*
   专门用来下载图片和优化图片加载的，跟缓存没关系
 
         如何实现异步下载，也就是多张图片同时下载？
         如何处理同一张图片（同一个 URL）多次下载的情况？
 
 SDWebImage通过这两个类(SDWebImageDownloader和SDWebImageDownloaderOperation)处理图片的网络加载。
 SDWebImageManager通过属性imageDownloader持有SDWebImageDownloader并且调用它的downloadImageWithURL来从网络加载图片。
 SDWebImageDownloader实现了图片加载的具体处理，如果图片在缓存存在则从缓存区，如果缓存不存在，则直接创建一个SDWebImageDownloaderOperation对象来下载图片。
 管理NSURLRequest对象请求头的封装、缓存、cookie的设置。加载选项的处理等功能。管理Operation之间的依赖关系。
 SDWebImageDownloaderOperation是一个自定义的并行Operation子类。
 这个类主要实现了图片下载的具体操作、以及图片下载完成以后的图片解压缩、Operation生命周期管理等。
 
 
 
 SDWebImageDownlaoder是一个单列对象，主要做了如下工作：
 
 定义了SDWebImageDownloaderOptions这个枚举属性，通过这个枚举属性来设置图片从网络加载的不同情况。
 定义并管理了NSURLSession对象，通过这个对象来做网络请求，并且实现对象的代理方法。
 定义一个NSURLRequest对象，并且管理请求头的拼装。
 对于每一个网络请求,通过一个SDWebImageDownloaderOperation自定义的NSOperation来操作网络下载。
 管理网络加载过程和完成时候的回调工作。通过addProgressCallback实现。
 */

#import <Foundation/Foundation.h>
#import "SDWebImageCompat.h"
#import "SDWebImageOperation.h"

 
typedef NS_OPTIONS(NSUInteger, SDWebImageDownloaderOptions) {
    SDWebImageDownloaderLowPriority = 1 << 0,
    // 带有进度
    SDWebImageDownloaderProgressiveDownload = 1 << 1,

    /**
     * 默认情况下，http请求阻止使用NSURLCache对象。如果设置了这个标记，则NSURLCache会被http请求使用。
     * By default, request prevent the use of NSURLCache. With this flag, NSURLCache
     * is used with default policies.
     */
    SDWebImageDownloaderUseNSURLCache = 1 << 2,

    /**
     * 如果image/imageData是从NSURLCache返回的。则completion这个回调会返回nil。
     * Call completion block with nil image/imageData if the image was read from NSURLCache
     * (to be combined with `SDWebImageDownloaderUseNSURLCache`).
     */
    SDWebImageDownloaderIgnoreCachedResponse = 1 << 3,
    
    /**
     * 支持后台下载
     * 如果app进入后台模式，是否继续下载。这个是通过在后台申请时间来完成这个操作。如果指定的时间范围内没有完成，则直接取消下载。
     * In iOS 4+, continue the download of the image if the app goes to background. This is achieved by asking the system for
     * extra time in background to let the request finish. If the background task expires the operation will be cancelled.
     */
    SDWebImageDownloaderContinueInBackground = 1 << 4,

    /**
     * 使用Cookies
     * 处理缓存在`NSHTTPCookieStore`对象里面的cookie。
     * 通过设置`NSMutableURLRequest.HTTPShouldHandleCookies = YES`来实现的。
     
     * Handles cookies stored in NSHTTPCookieStore by setting 
     * NSMutableURLRequest.HTTPShouldHandleCookies = YES;
     */
    SDWebImageDownloaderHandleCookies = 1 << 5,

    /**
     * 允许验证SSL
     * 允许非信任的SSL证书请求。
     * 在测试的时候很有用。但是正式环境要小心使用。
     * Enable to allow untrusted SSL certificates.
     * Useful for testing purposes. Use with caution in production.
     */
    SDWebImageDownloaderAllowInvalidSSLCertificates = 1 << 6,

    /**
     * 默认情况下，图片加载的顺序是根据加入队列的顺序加载的。但是这个标记会把任务加入队列的最前面。
     * Put the image in the high priority queue.
     */
    SDWebImageDownloaderHighPriority = 1 << 7,
    
    /**
     * 默认情况下，图片会按照他的原始大小来解码显示。这个属性会调整图片的尺寸到合适的大小根据设备的内存限制。
     * 如果`SDWebImageProgressiveDownload`标记被设置了，则这个flag不起作用。
     * Scale down the image // 裁剪大图片
     */
    SDWebImageDownloaderScaleDownLargeImages = 1 << 8,
};
//当判断self.option是否是SDWebImageDownloaderIgnoreCachedResponse选项时，应该这么判断：
//  self.option & SDWebImageDownloaderIgnoreCachedResponse



/**
    下载任务执行顺序

    用来表示下载时数据被调用的顺序。
 
 　　FIFO (first-in-first-out 先进先出)、LIFO (last-in-first-out 后进先出)，下载图像一般按照放入队列中的顺序依次进行，不过这里同时也支持后放入队列任务的先下载的操作。
 
 　　一个下载管理器应该这样管理下载，肯定有一个下载列表，可以假定这个列表保存在一个数组中，正常情况下应该每次取出数组中第1个元素来下载，这就是 FIFO (先进先出)。那么要改为 LIFO (后进先出)，应该是针对某一个下载的，不应该是把取出数据的顺序改为从数组的最后一个元素取出。
 */
typedef NS_ENUM(NSInteger, SDWebImageDownloaderExecutionOrder) {
    /**
     * Default value. All download operations will execute in queue style (first-in-first-out).
     */
    SDWebImageDownloaderFIFOExecutionOrder, // 队列  先进先出

    /**
     * All download operations will execute in stack style (last-in-first-out).
     */
    SDWebImageDownloaderLIFOExecutionOrder// 栈  后进先出
};

FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadStartNotification;
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadStopNotification;

typedef void(^SDWebImageDownloaderProgressBlock)(NSInteger receivedSize, NSInteger expectedSize, NSURL * _Nullable targetURL);

typedef void(^SDWebImageDownloaderCompletedBlock)(UIImage * _Nullable image, NSData * _Nullable data, NSError * _Nullable error, BOOL finished);

typedef NSDictionary<NSString *, NSString *> SDHTTPHeadersDictionary;
typedef NSMutableDictionary<NSString *, NSString *> SDHTTPHeadersMutableDictionary;

typedef SDHTTPHeadersDictionary * _Nullable (^SDWebImageDownloaderHeadersFilterBlock)(NSURL * _Nullable url, SDHTTPHeadersDictionary * _Nullable headers);

/**
 　　这个类表示与每一个下载相关的 token，能用于取消一个下载。
 　　SDWebImageDownloadToken 作为每一个下载的唯一身份标识。
 *  A token associated with each download. Can be used to cancel a download
 */
@interface SDWebImageDownloadToken : NSObject

@property (nonatomic, strong, nullable) NSURL *url;
@property (nonatomic, strong, nullable) id downloadOperationCancelToken;

@end


/**
 * Asynchronous downloader dedicated and optimized for image loading.
 */
@interface SDWebImageDownloader : NSObject

/**
 * Decompressing images that are downloaded and cached can improve performance but can consume lot of memory.
 * Defaults to YES. Set this to NO if you are experiencing a crash due to excessive memory consumption.
 
* 当图片下载完成以后，加压缩图片以后再换成。这样可以提升性能但是会占用更多的存储空间。
* 模式YES,如果你因为过多的内存消耗导致一个奔溃，可以把这个属性设置为NO。
*/
@property (assign, nonatomic) BOOL shouldDecompressImages; // 下载完成后是否需要解压缩图片，默认为 YES

/**
 *  最大并行下载的数量
 *  The maximum number of concurrent downloads
 */
@property (assign, nonatomic) NSInteger maxConcurrentDownloads;

/**
  当前并行下载数量
 * Shows the current amount of downloads that still need to be downloaded
 */
@property (readonly, nonatomic) NSUInteger currentDownloadCount;

/**
 下载超时时间设置
 *  The timeout value (in seconds) for the download operation. Default: 15.0.
 */
@property (assign, nonatomic) NSTimeInterval downloadTimeout;

/**
 * The configuration in use by the internal NSURLSession.
 * Mutating this object directly has no effect.
 *
 * @see createNewSessionWithConfiguration:
 */
@property (readonly, nonatomic, nonnull) NSURLSessionConfiguration *sessionConfiguration;


/**
  改变下载operation的执行顺序。默认是FIFO。
 * Changes download operations execution order. Default value is `SDWebImageDownloaderFIFOExecutionOrder`.
 */
@property (assign, nonatomic) SDWebImageDownloaderExecutionOrder executionOrder;

/**
 单列方法。返回一个单列对象
 返回一个单列的SDWebImageDownloader对象
 *  Singleton method, returns the shared instance
 *
 *  @return global shared instance of downloader class
 */
+ (nonnull instancetype)sharedDownloader;

/**
    为图片加载request设置一个SSL证书对象。
 *  Set the default URL credential to be set for request operations.
 */
@property (strong, nonatomic, nullable) NSURLCredential *urlCredential;

/**
  Basic认证请求设置用户名和密码
 * Set username
 */
@property (strong, nonatomic, nullable) NSString *username;

/**
 * Set password
 */
@property (strong, nonatomic, nullable) NSString *password;

/**
 * 为http请求设置header。
 * 每一request执行的时候，这个Block都会被执行。用于向http请求添加请求域。
 * Set filter to pick headers for downloading image HTTP request.
 *
 * This block will be invoked for each downloading image request, returned
 * NSDictionary will be used as headers in corresponding HTTP request.
 */
@property (nonatomic, copy, nullable) SDWebImageDownloaderHeadersFilterBlock headersFilter;

/**
 * 初始化一个请求对象
 
 * @param sessionConfiguration NSURLSessionTask初始化配置
 * @return 返回一个SDWebImageDownloader对象
 * 使用NS_DESIGNATED_INITIALIZER强调该方法是建议的初始化方法。
 
 * Creates an instance of a downloader with specified session configuration.
 * @note `timeoutIntervalForRequest` is going to be overwritten.
 * @return new instance of downloader class
 */
- (nonnull instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)sessionConfiguration NS_DESIGNATED_INITIALIZER;

/**
  设置请求头域
 
  请求头域值
  请求头域名
 * Set a value for a HTTP header to be appended to each download HTTP request.
 *
 * @param value The value for the header field. Use `nil` value to remove the header.
 * @param field The name of the header field to set.
 */
- (void)setValue:(nullable NSString *)value forHTTPHeaderField:(nullable NSString *)field;

/**
 * 获取请求头域的值
 * Returns the value of the specified HTTP header field.
 *
 * @return The value associated with the header field field, or `nil` if there is no corresponding header field.
 */
- (nullable NSString *)valueForHTTPHeaderField:(nullable NSString *)field;

/**
 * 创建 operation 用的类
 * 设置一个`SDWebImageDownloaderOperation`的子类作为`NSOperation`来构建request来下载一张图片。
 * operationClass 指定的子类
 * Sets a subclass of `SDWebImageDownloaderOperation` as the default
 * `NSOperation` to be used each time SDWebImage constructs a request
 * operation to download an image.
 *
 * @param operationClass The subclass of `SDWebImageDownloaderOperation` to set 
 *        as default. Passing `nil` will revert to `SDWebImageDownloaderOperation`.
 */
- (void)setOperationClass:(nullable Class)operationClass;

/**
 
  新建一个SDWebImageDownloadOperation对象来来做具体的下载操作。同时指定缓存策略、cookie策略、自定义请求头域等。
 
   url url
   options 加载选项
   progressBlock 进度progress
   completedBlock 完成回调
   返回一个SDWebImageDownloadToken，用于关联一个请求
 
 * Creates a SDWebImageDownloader async downloader instance with a given URL
 *
 * The delegate will be informed when the image is finish downloaded or an error has happen.
 *
 * @see SDWebImageDownloaderDelegate
 *
 * @param url            The URL to the image to download
 * @param options        The options to be used for this download
 * @param progressBlock  A block called repeatedly while the image is downloading
 *                       @note the progress block is executed on a background queue
 * @param completedBlock A block called once the download is completed.
 *                       If the download succeeded, the image parameter is set, in case of error,
 *                       error parameter is set with the error. The last parameter is always YES
 *                       if SDWebImageDownloaderProgressiveDownload isn't use. With the
 *                       SDWebImageDownloaderProgressiveDownload option, this block is called
 *                       repeatedly with the partial image object and the finished argument set to NO
 *                       before to be called a last time with the full image and finished argument
 *                       set to YES. In case of error, the finished argument is always YES.
 *
 * @return A token (SDWebImageDownloadToken) that can be passed to -cancel: to cancel this operation
 */
- (nullable SDWebImageDownloadToken *)downloadImageWithURL:(nullable NSURL *)url
                                                   options:(SDWebImageDownloaderOptions)options
                                                  progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                                 completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock;

/**
 * Cancels a download that was previously queued using -downloadImageWithURL:options:progress:completed:
 *
 * @param token The token received from -downloadImageWithURL:options:progress:completed: that should be canceled.
 */
- (void)cancel:(nullable SDWebImageDownloadToken *)token;

/**
 * Sets the download queue suspension state
 */
- (void)setSuspended:(BOOL)suspended;

/**
 * Cancels all download operations in the queue
 */
- (void)cancelAllDownloads;

/**
 * Forces SDWebImageDownloader to create and use a new NSURLSession that is
 * initialized with the given configuration.
 * @note All existing download operations in the queue will be cancelled.
 * @note `timeoutIntervalForRequest` is going to be overwritten.
 *
 * @param sessionConfiguration The configuration to use for the new NSURLSession
 */
- (void)createNewSessionWithConfiguration:(nonnull NSURLSessionConfiguration *)sessionConfiguration;

/**
 * Invalidates the managed session, optionally canceling pending operations.
 * @note If you use custom downloader instead of the shared downloader, you need call this method when you do not use it to avoid memory leak
 * @param cancelPendingOperations Whether or not to cancel pending operations.
 */
- (void)invalidateSessionAndCancel:(BOOL)cancelPendingOperations;

@end
