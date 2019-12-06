/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import <Foundation/Foundation.h>
#import "SDWebImageCompat.h"

@interface SDImageCacheConfig : NSObject

/**
 * Decompressing images that are downloaded and cached can improve performance but can consume lot of memory.
 * Defaults to YES. Set this to NO if you are experiencing a crash due to excessive memory consumption.
 * 是否在缓存之前解压图片，此项操作可以提升性能，但是会消耗较多的内存，默认是YES。注意:如果内存不足，可以置为NO
 */
@property (assign, nonatomic) BOOL shouldDecompressImages;

/**是否禁止iCloud备份，默认是YES
 * disable iCloud backup [defaults to YES]
 */
@property (assign, nonatomic) BOOL shouldDisableiCloud;

/**是否启用内存缓存 默认是YES
 * use memory cache [defaults to YES]
 */
@property (assign, nonatomic) BOOL shouldCacheImagesInMemory;

/**
 * The reading options while reading cache from disk.
 * Defaults to 0. You can set this to mapped file to improve performance.
 */
@property (assign, nonatomic) NSDataReadingOptions diskCacheReadingOptions;

/**
 * The maximum length of time to keep an image in the cache, in seconds.
 * 磁盘缓存的最大时长，也就是说缓存存多久后需要删掉
 */
@property (assign, nonatomic) NSInteger maxCacheAge;

/**
 * The maximum size of the cache, in bytes.
 * 磁盘缓存文件总体积最大限制，以 bytes 来计算
 */
@property (assign, nonatomic) NSUInteger maxCacheSize;

@end
