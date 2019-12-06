/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCache.h"
#import <CommonCrypto/CommonDigest.h>
#import "NSImage+WebCache.h"
#import "SDWebImageCodersManager.h"

// See https://github.com/rs/SDWebImage/pull/1141 for discussion

/*
 
 SDImageCache 的内存缓存是通过一个继承 NSCache 的 AutoPurgeCache 类来实现的，NSCache 是一个类似于 NSMutableDictionary 存储 key-value 的容器，主要有以下几个特点：
 
 1.自动删除机制：当系统内存紧张时，NSCache会自动删除一些缓存对象
 2.线程安全：从不同线程中对同一个 NSCache 对象进行增删改查时，不需要加锁
 3.不同于 NSMutableDictionary，NSCache存储对象时不会对 key 进行 copy 操作
 4.SDImageCache 的磁盘缓存是通过异步操作 NSFileManager 存储缓存文件到沙盒来实现的。
 
 */
@interface AutoPurgeCache : NSCache
@end

@implementation AutoPurgeCache

- (nonnull instancetype)init {
    self = [super init];
    if (self) {
#if SD_UIKIT//内存警告
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(removeAllObjects) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    }
    return self;
}

- (void)dealloc {
#if SD_UIKIT
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
}

@end
//　图片在缓存中的大小是通过像素来衡量的。
// 内联函数（类似宏定义）--图片消耗的内存空间
FOUNDATION_STATIC_INLINE NSUInteger SDCacheCostForImage(UIImage *image) {
#if SD_MAC
    return image.size.height * image.size.width;
#elif SD_UIKIT || SD_WATCH
    return image.size.height * image.size.width * image.scale * image.scale;
#endif
}

@interface SDImageCache ()

#pragma mark - Properties
//内存缓存
@property (strong, nonatomic, nonnull) NSCache *memCache;
//磁盘缓存路径
@property (strong, nonatomic, nonnull) NSString *diskCachePath;
//自定义的缓存路径
@property (strong, nonatomic, nullable) NSMutableArray<NSString *> *customPaths;
//磁盘缓存操作的串行队列
@property (strong, nonatomic, nullable) dispatch_queue_t ioQueue;
//　ioQueue 这是用于输入和输出的队列，队列其实往往可以当做一种"锁"来使用，把某些任务放在串行队列里面按照顺序一步一步的执行，必须考虑线程是否安全。
@end


@implementation SDImageCache {
    NSFileManager *_fileManager;
}

#pragma mark - Singleton, init, dealloc

// 单例方法，返回一个全局的缓存实例
+ (nonnull instancetype)sharedImageCache {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

/*
 -init
    -initWithNamespace:
        -makeDiskCachePath:
        -initWithNamespace:diskCacheDirectory:

 */
- (instancetype)init {
    return [self initWithNamespace:@"default"];
}
/**
 使用指定的命名空间实例化一个新的缓存存储
 
 @param ns 命名空间
 @return 缓存实例
 */

- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns {
    //初始化缓存目录路径
    NSString *path = [self makeDiskCachePath:ns];
    return [self initWithNamespace:ns diskCacheDirectory:path];
}


/**
 -initWithNamespace:diskCacheDirectory: 是一个 Designated Initializer，
 这个方法中主要是初始化实例变量、属性，设置属性默认值，并根据 namespace 设置完整的缓存目录路径，
 除此之外，还针对 iOS 添加了通知观察者，用于内存紧张时清空内存缓存，以及程序终止运行时和程序退到后台时清扫磁盘缓存。
 */
- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns
                       diskCacheDirectory:(nonnull NSString *)directory {
    if ((self = [super init])) {
         //最内层文件夹名（com.hackemist.SDWebImageCache.default）
        NSString *fullNamespace = [@"com.hackemist.SDWebImageCache." stringByAppendingString:ns];
        
        // Create IO serial queue
        // 创建有一个IO操作的串行队列
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);
        
        _config = [[SDImageCacheConfig alloc] init];
        
         // 创建缓存对象
        // Init the memory cache
        _memCache = [[AutoPurgeCache alloc] init];
        _memCache.name = fullNamespace;

        // Init the disk cache
           // 初始化磁盘缓存地址
        if (directory != nil) {
            _diskCachePath = [directory stringByAppendingPathComponent:fullNamespace];
        } else {
            NSString *path = [self makeDiskCachePath:ns];
            _diskCachePath = path;
        }
   
          //在IO线程创建管理对象
        dispatch_sync(_ioQueue, ^{
            _fileManager = [NSFileManager new];
        });

#if SD_UIKIT
        // Subscribe to app events
        //内存警告时会清除内存缓存
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        //app终止时，会整理沙盒缓存
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deleteOldFiles)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];
        //app进入后台时，会在后台整理沙盒缓存
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundDeleteOldFiles)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


/**
     使用 dispatch_queue_get_label 返回创建队列时的添加的自定义的队列的标识（const char *_Nullable label），
     主队列返回的是: "com.apple.main-thread"。
     _ioQueue 返回的是 "com.hackemist.SDWebImageCache"，
     使用 DISPATCH_CURRENT_QUEUE_LABEL 做参数可返回当前队列的标识。
     由此检查当前队列是不是 _ioQueue。
 */

- (void)checkIfQueueIsIOQueue {
    
    const char *currentQueueLabel = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    const char *ioQueueLabel = dispatch_queue_get_label(self.ioQueue);
    if (strcmp(currentQueueLabel, ioQueueLabel) != 0) {
        NSLog(@"This method should be called from the ioQueue");
    }
}


#pragma mark - Cache paths

- (void)addReadOnlyCachePath:(nonnull NSString *)path {
    if (!self.customPaths) {
        self.customPaths = [NSMutableArray new];
    }

    if (![self.customPaths containsObject:path]) {
        [self.customPaths addObject:path];
    }
}

- (nullable NSString *)cachePathForKey:(nullable NSString *)key inPath:(nonnull NSString *)path {
    NSString *filename = [self cachedFileNameForKey:key];
    return [path stringByAppendingPathComponent:filename];
}

- (nullable NSString *)defaultCachePathForKey:(nullable NSString *)key {
    return [self cachePathForKey:key inPath:self.diskCachePath];
}



<<<<<<< HEAD
//主要先看一下这个方法的实现，这个方法的主要功能是根据图片的 URL 返回一个 MD5 处理的文件名。
//这里的参数 key 多为图片的 URL，把图片的 URL 使用 MD5 方式转化，同时当 URL 有后缀的时候，做加点处理。
=======
/**
 这里的参数 key 多为图片的 URL，把图片的 URL 使用 MD5 方式转化，同时当 URL 有后缀的时候，做加点处理。
 */
>>>>>>> c3185d69dd8b20c9c451522d995d31bf8cbe0688
- (nullable NSString *)cachedFileNameForKey:(nullable NSString *)key {
    const char *str = key.UTF8String;
    if (str == NULL) {
        str = "";
    }
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSURL *keyURL = [NSURL URLWithString:key];
    NSString *ext = keyURL ? keyURL.pathExtension : key.pathExtension;
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15], ext.length == 0 ? @"" : [NSString stringWithFormat:@".%@", ext]];
    return filename;
}

- (nullable NSString *)makeDiskCachePath:(nonnull NSString*)fullNamespace {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [paths[0] stringByAppendingPathComponent:fullNamespace];
}

#pragma mark - Store Ops
// 以key为键值将图片image存储到缓存中
- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    [self storeImage:image imageData:nil forKey:key toDisk:YES completion:completionBlock];
}
// 以key为键值将图片image存储到缓存中
- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    [self storeImage:image imageData:nil forKey:key toDisk:toDisk completion:completionBlock];
}

// 把一张图片存入缓存的具体实现
//存储图片（是否重新计算  是否在沙盒中）
- (void)storeImage:(nullable UIImage *)image
         imageData:(nullable NSData *)imageData
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    
    
    if (!image || !key) {
        if (completionBlock) {
            completionBlock();
        }
        return;
    }
   
     // if memory cache is enabled
     // 如果设置是需要缓存在内存，就缓存在内存中
     // 先计算出图像的占用内存，使用 _memCache 缓存图像到内存中。这个过程是非常快的，因此不用考虑线程。
    if (self.config.shouldCacheImagesInMemory) {
        //计算缓存数据的大小
        NSUInteger cost = SDCacheCostForImage(image);
        //加入缓存
        [self.memCache setObject:image forKey:key cost:cost];
    }
    
//先计算出图像的占用内存，使用 _memCache 缓存图像到内存中。这个过程是非常快的，因此不用考虑线程。
//如果 toDisk 为真，在串行队列 _ioQueue 中异步执行：
    
      //要缓存在沙盒中
    if (toDisk) {
        //在一个串行队列中做磁盘缓存操作
        //如果 toDisk 为真，在串行队列 _ioQueue 中异步执行：
        dispatch_async(self.ioQueue, ^{
            @autoreleasepool {
                NSData *data = imageData;
                if (!data && image) {
                    //获取图片的类型GIF/PNG等
                    //根据指定的SDImageFormat，把图片转换为对应的data数据
                    // If we do not have any data to detect image format, use PNG format
                    data = [[SDWebImageCodersManager sharedInstance] encodedDataWithImage:image format:SDImageFormatPNG];
                }
                //把处理好了的数据存入磁盘
                [self storeImageDataToDisk:data forKey:key];
            }
            
            if (completionBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock();
                });
            }
        });
    } else {
        if (completionBlock) {
            completionBlock();
        }
    }
}

//把图片资源存入磁盘
//这个方法主要是实现把图像转化为 NSData 类型数据根据文件名 key 存入磁盘中。
- (void)storeImageDataToDisk:(nullable NSData *)imageData forKey:(nullable NSString *)key {
     //如果有图片 && （重新计算或没有data）---&gt;就要通过image获取data
    if (!imageData || !key) {
        return;
    }
    
    [self checkIfQueueIsIOQueue];
    //判断_diskCachePath的路径是否存在，没有就创建路径（创建对应的文件夹）
    //.../Library/Caches/default/com.hackemist.SDWebImageCache.default
    if (![_fileManager fileExistsAtPath:_diskCachePath]) {
        [_fileManager createDirectoryAtPath:_diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    
    // get cache Path for image key
    // 获取image key 的缓存路径
    //.../Library/Caches/default/com.hackemist.SDWebImageCache.default/24dd60428e4a8af2a2da3d87a226ab9b.png
    NSString *cachePathForKey = [self defaultCachePathForKey:key];
    // transform to NSUrl
    // 转换成 NSUrl
    NSURL *fileURL = [NSURL fileURLWithPath:cachePathForKey];
     //将data储存起来
    [_fileManager createFileAtPath:cachePathForKey contents:imageData attributes:nil];
    
    // disable iCloud backup
    // 是否上传iCould
    if (self.config.shouldDisableiCloud) {
        [fileURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
}

#pragma mark - Query and Retrieve Ops
// 根据key判断磁盘缓存中是否存在图片
- (void)diskImageExistsWithKey:(nullable NSString *)key completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    
    dispatch_async(_ioQueue, ^{
        BOOL exists = [_fileManager fileExistsAtPath:[self defaultCachePathForKey:key]];

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
         // 要确认有带拓展名的和没带拓展名的
        if (!exists) {
            exists = [_fileManager fileExistsAtPath:[self defaultCachePathForKey:key].stringByDeletingPathExtension];
        }
       //在主线程回调completionBlock
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(exists);
            });
        }
    });
}
//根据key获取缓存在内存中的图片
- (nullable UIImage *)imageFromMemoryCacheForKey:(nullable NSString *)key {
    return [self.memCache objectForKey:key];
}

//根据key获取缓存在磁盘中的图片
- (nullable UIImage *)imageFromDiskCacheForKey:(nullable NSString *)key {
    //从沙盒缓存中获取
    UIImage *diskImage = [self diskImageForKey:key];
     //如果沙盒缓存中有 && 设置是需要缓存图片
    if (diskImage && self.config.shouldCacheImagesInMemory) {
         //将图片缓存在内存中
        NSUInteger cost = SDCacheCostForImage(diskImage);
        [self.memCache setObject:diskImage forKey:key cost:cost];
    }

    return diskImage;
}

// 根据key获取缓存图片(先从内存中搜索，再去磁盘中搜索)
- (nullable UIImage *)imageFromCacheForKey:(nullable NSString *)key {
    // First check the in-memory cache...
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        return image;
    }
    
    // Second check the disk cache...
    image = [self imageFromDiskCacheForKey:key];
    return image;
}

// 根据指定的key，获取存储在磁盘上的数据
- (nullable NSData *)diskImageDataBySearchingAllPathsForKey:(nullable NSString *)key {
    //获取key对应的path
    NSString *defaultPath = [self defaultCachePathForKey:key];
    NSData *data = [NSData dataWithContentsOfFile:defaultPath options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }
    // 注意要使用有带拓展名的和没带拓展名的地址来获取一遍
    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    //如果key没有后缀名，则会走到这里通过这里读取
    data = [NSData dataWithContentsOfFile:defaultPath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }
    //如果在默认路径没有找到图片，则在自定义路径迭代查找
    NSArray<NSString *> *customPaths = [self.customPaths copy];
    for (NSString *path in customPaths) {
        NSString *filePath = [self cachePathForKey:key inPath:path];
        NSData *imageData = [NSData dataWithContentsOfFile:filePath options:self.config.diskCacheReadingOptions error:nil];
        if (imageData) {
            return imageData;
        }
        // 注意要使用有带拓展名的和没带拓展名的地址来获取一遍
        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        imageData = [NSData dataWithContentsOfFile:filePath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];
        if (imageData) {
            return imageData;
        }
    }

    return nil;
}

//根据指定的key获取image对象
- (nullable UIImage *)diskImageForKey:(nullable NSString *)key {
    //通过key从磁盘中获取图片data
    NSData *data = [self diskImageDataBySearchingAllPathsForKey:key];
    if (data) {
        //将data转成image（其中有包括调整方向）
        UIImage *image = [[SDWebImageCodersManager sharedInstance] decodedImageWithData:data];
        //将里面@2x或@3x的转换成正确比例的image
        image = [self scaledImageForKey:key image:image];
         //如果有设置解压属性（即提前解压属性）就去解压
        if (self.config.shouldDecompressImages) {
            image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&data options:@{SDWebImageCoderScaleDownLargeImagesKey: @(NO)}];
        }
        return image;
    } else {
        return nil;
    }
}

- (nullable UIImage *)scaledImageForKey:(nullable NSString *)key image:(nullable UIImage *)image {
    return SDScaledImageForKey(key, image);
}

// 在缓存中查询对应key的数据
- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key done:(nullable SDCacheQueryCompletedBlock)doneBlock {
    
    if (!key) {
         //判断输入参数
        if (doneBlock) {
            doneBlock(nil, nil, SDImageCacheTypeNone);
        }
        return nil;
    }
    
    // 首先通过url作为key从内存缓存中去获取
    // 首先从内存中查找图片
    // First check the in-memory cache...
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        NSData *diskData = nil;
        if (image.images) {
            diskData = [self diskImageDataBySearchingAllPathsForKey:key];
        }
        if (doneBlock) {
            doneBlock(image, diskData, SDImageCacheTypeMemory);
        }
        return nil;
    }
    
    //内存缓存没有
    //新建一个NSOperation来获取磁盘图片 ？？？？？？？？
    //在 _ioQueue 中异步执行，创建一个 NSOperation 类型的 operation，如果 operation 取消了则直接 return。
    NSOperation *operation = [NSOperation new];
     //在IO队列中去查找沙盒中的图片
    dispatch_async(self.ioQueue, ^{
        if (operation.isCancelled) {
            // do not call the completion if cancelled
            return;
        }
        
        //在一个自动释放池中处理图片从磁盘加载

        @autoreleasepool {
         
            NSData *diskData = [self diskImageDataBySearchingAllPathsForKey:key];
                //通过key去沙盒获取image
            UIImage *diskImage = [self diskImageForKey:key];
              //如果沙盒有，并且需要缓存图片则缓存起来
            if (diskImage && self.config.shouldCacheImagesInMemory) {
                //获得图片消耗的内存大小
                NSUInteger cost = SDCacheCostForImage(diskImage);
                //把从磁盘取出的缓存图片加入内存缓存中
                [self.memCache setObject:diskImage forKey:key cost:cost];
            }
            //图片处理完成以后回调Block

            if (doneBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    doneBlock(diskImage, diskData, SDImageCacheTypeDisk);
                });
            }
        }
    });

    return operation;
}

#pragma mark - Remove Ops
//通过key从磁盘和内存中移除缓存

- (void)removeImageForKey:(nullable NSString *)key withCompletion:(nullable SDWebImageNoParamsBlock)completion {
    [self removeImageForKey:key fromDisk:YES withCompletion:completion];
}

// 移除指定key对应的缓存数据
- (void)removeImageForKey:(nullable NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(nullable SDWebImageNoParamsBlock)completion {
    if (key == nil) {
        return;
    }
    //删除内存中的缓存
    if (self.config.shouldCacheImagesInMemory) {
        [self.memCache removeObjectForKey:key];
    }
    
    //是否也要删除沙盒中的缓存
    if (fromDisk) {
        dispatch_async(self.ioQueue, ^{
            [_fileManager removeItemAtPath:[self defaultCachePathForKey:key] error:nil];
            
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
        });
    } else if (completion){
        completion();
    }
    
}

# pragma mark - Mem Cache settings

- (void)setMaxMemoryCost:(NSUInteger)maxMemoryCost {
    self.memCache.totalCostLimit = maxMemoryCost;
}

- (NSUInteger)maxMemoryCost {
    return self.memCache.totalCostLimit;
}

- (NSUInteger)maxMemoryCountLimit {
    return self.memCache.countLimit;
}

- (void)setMaxMemoryCountLimit:(NSUInteger)maxCountLimit {
    self.memCache.countLimit = maxCountLimit;
}

#pragma mark - Cache clean Ops
//清除内存缓存
- (void)clearMemory {
    [self.memCache removeAllObjects];
}
//清除沙盒的缓存，完成后执行传入的block
- (void)clearDiskOnCompletion:(nullable SDWebImageNoParamsBlock)completion {
    //在io队列中异步执行清除操作
    dispatch_async(self.ioQueue, ^{
        //清除文件夹
        [_fileManager removeItemAtPath:self.diskCachePath error:nil];
        //再创建个空的文件夹
        [_fileManager createDirectoryAtPath:self.diskCachePath
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL];
         //主线程回调传入的block（completion）
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

- (void)deleteOldFiles {
    [self deleteOldFilesWithCompletionBlock:nil];
}
/**
 当应用终止或者进入后台都会调用这个方法来清除缓存图片
 这里会根据图片存储时间来清理图片，默认是一周，从最老的图片开始清理。如果图片缓存空间小于一个规定值，则不考虑
 
 @param completionBlock 清除完成以后的回调
 */
- (void)deleteOldFilesWithCompletionBlock:(nullable SDWebImageNoParamsBlock)completionBlock {
    //获取磁盘缓存的默认根目录

    dispatch_async(self.ioQueue, ^{
        NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];
        NSArray<NSString *> *resourceKeys = @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey];
// 这个枚举器为我们的缓存文件预取有用的属性.
        // This enumerator prefetches useful properties for our cache files.
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:resourceKeys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];
  //求出过期的时间点
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.config.maxCacheAge];
        NSMutableDictionary<NSURL *, NSDictionary<NSString *, id> *> *cacheFiles = [NSMutableDictionary dictionary];
        NSUInteger currentCacheSize = 0;

        // Enumerate all of the files in the cache directory.  This loop has two purposes:
        //
        //  1. Removing files that are older than the expiration date.
        //  2. Storing file attributes for the size-based cleanup pass.
        
        //迭代缓存目录。有两个目的：
        //1 删除比指定日期更老的图片
        //2 记录文件的大小，以提供给后面删除使用
        NSMutableArray<NSURL *> *urlsToDelete = [[NSMutableArray alloc] init];
        
        //枚举器获取所有文件的url
        for (NSURL *fileURL in fileEnumerator) {
            NSError *error;
            //获取文件的相关属性字典
            //获取指定url对应文件的指定三种属性的key和value
            NSDictionary<NSString *, id> *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:&error];
             // 跳过文件夹
            // Skip directories and errors.
            //如果是文件夹则返回

            if (error || !resourceValues || [resourceValues[NSURLIsDirectoryKey] boolValue]) {
                continue;
            }
            // 移除比过期时间点更早的文件;
            //获取指定url文件对应的修改日期

            // Remove files that are older than the expiration date;
            NSDate *modificationDate = resourceValues[NSURLContentModificationDateKey];
            //通过文件创建日期和过期时间点的比较来判断是否过期
            //如果修改日期大于指定日期，则加入要移除的数组里
            if ([[modificationDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [urlsToDelete addObject:fileURL];
                continue;
            }
             //获取指定的url对应的文件的大小，并且把url与对应大小存入一个字典中

            // Store a reference to this file and account for its total size.
            NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
            //当前缓存总大小
            currentCacheSize += totalAllocatedSize.unsignedIntegerValue;
            //将该文件的属性字典保存在cacheFiles中，以fileURL为key
            cacheFiles[fileURL] = resourceValues;
        }
         //删除所有最后修改日期大于指定日期的所有文件

        for (NSURL *fileURL in urlsToDelete) {
            [_fileManager removeItemAtURL:fileURL error:nil];
        }
        
        
        // 如果我们剩下的磁盘缓存大小还是超过配置的容量，就再次进行清理
        // 当前容量大于设置的maxCacheSize
        // If our remaining disk cache exceeds a configured maximum size, perform a second
        // size-based cleanup pass.  We delete the oldest files first.
        
        //如果当前缓存的大小超过了默认大小，则按照日期删除，直到缓存大小<默认大小的一半

        if (self.config.maxCacheSize > 0 && currentCacheSize > self.config.maxCacheSize) {
            // Target half of our maximum cache size for this cleanup pass.
            // 一个期望的内存大小是配置容量的一半
            const NSUInteger desiredCacheSize = self.config.maxCacheSize / 2;
            //通过日期来排序，最旧的放在数组前面
            //根据文件创建的时间排序

            // Sort the remaining cache files by their last modification time (oldest first).
            NSArray<NSURL *> *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                                     usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                                         return [obj1[NSURLContentModificationDateKey] compare:obj2[NSURLContentModificationDateKey]];
                                                                     }];
            // 删除文件直到达到我们的目标容量.
            //迭代删除缓存，直到缓存大小是默认缓存大小的一半

            // Delete files until we fall below our desired cache size.
            for (NSURL *fileURL in sortedFiles) {
                if ([_fileManager removeItemAtURL:fileURL error:nil]) {
                    NSDictionary<NSString *, id> *resourceValues = cacheFiles[fileURL];
                    NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                    //计算当前缓存总大小
                    currentCacheSize -= totalAllocatedSize.unsignedIntegerValue;
                    //如果当前缓存总大小小于目标容量，就不用删除了
                    if (currentCacheSize < desiredCacheSize) {
                        break;
                    }
                }
            }
        }
        //执行完毕，主线程回调
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock();
            });
        }
    });
}

#if SD_UIKIT
// 应用进入后台的时候，调用这个方法
- (void)backgroundDeleteOldFiles {
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    UIApplication *application = [UIApplication performSelector:@selector(sharedApplication)];
    //如果backgroundTask对应的时间结束了，任务还没有处理完成，则直接终止任务
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        // Clean up any unfinished task business by marking where you
        // stopped or ending the task outright.
        //当任务非正常终止的时候，做清理工作
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];

    //图片清理结束以后，处理完成

    // Start the long-running task and return immediately.
    [self deleteOldFilesWithCompletionBlock:^{
        //清理完成以后，终止任务

        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
}
#endif

#pragma mark - Cache Info
//获取磁盘缓存文件总大小（在ioQueue中） 通过_fileManager在iO队列中去异步获取的。
- (NSUInteger)getSize {
    __block NSUInteger size = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        for (NSString *fileName in fileEnumerator) {
            NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
            NSDictionary<NSString *, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
            size += [attrs fileSize];
        }
    });
    return size;
}
//获取磁盘缓存文件数量（在ioQueue中）
- (NSUInteger)getDiskCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtPath:self.diskCachePath];
        count = fileEnumerator.allObjects.count;
    });
    return count;
}

//计算磁盘缓存文件总大小和数量（在ioQueue中），并通过block传出

- (void)calculateSizeWithCompletionBlock:(nullable SDWebImageCalculateSizeBlock)completionBlock {
    NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

    dispatch_async(self.ioQueue, ^{
        NSUInteger fileCount = 0;
        NSUInteger totalSize = 0;

        NSDirectoryEnumerator *fileEnumerator = [_fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:@[NSFileSize]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        for (NSURL *fileURL in fileEnumerator) {
            NSNumber *fileSize;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
            totalSize += fileSize.unsignedIntegerValue;
            fileCount += 1;
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(fileCount, totalSize);
            });
        }
    });
}

@end

