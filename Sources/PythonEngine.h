#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PythonCompletion)(NSString * _Nullable result, NSError * _Nullable error);

@interface PythonEngine : NSObject
+ (PythonEngine *)shared NS_SWIFT_NAME(shared());
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *text);
- (void)runJSON:(NSString *)json completion:(PythonCompletion)completion NS_SWIFT_NAME(run(json:completion:));
- (void)importJSON:(NSString *)json completion:(PythonCompletion)completion NS_SWIFT_NAME(importProject(json:completion:));
- (void)requestStop;
@end

NS_ASSUME_NONNULL_END
