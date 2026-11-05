#import "PythonEngine.h"
#define PY_SSIZE_T_CLEAN
#include <Python/Python.h>
#include <stdatomic.h>

static atomic_bool cancellationRequested = false;
static void (^outputHandler)(NSString *);

static NSError *EngineError(NSString *message) {
    return [NSError errorWithDomain:@"PyPocket.Python" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message ?: @"Python 运行错误"}];
}

static PyObject *HostWrite(PyObject *self, PyObject *args) {
    const char *text;
    Py_ssize_t length;
    if (!PyArg_ParseTuple(args, "s#", &text, &length)) return NULL;
    NSString *message = [[NSString alloc] initWithBytes:text length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    if (outputHandler && message) outputHandler(message);
    Py_RETURN_NONE;
}

static PyObject *HostCancelled(PyObject *self, PyObject *args) {
    return PyBool_FromLong(atomic_load(&cancellationRequested));
}

static PyMethodDef hostMethods[] = {
    {"write", HostWrite, METH_VARARGS, "输出至原生控制台"},
    {"cancelled", HostCancelled, METH_NOARGS, "读取协作停止状态"},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef hostModule = {
    PyModuleDef_HEAD_INIT, "_pypocket_native", NULL, -1, hostMethods
};
static PyObject *InitHost(void) { return PyModule_Create(&hostModule); }

static NSString *TakePythonError(void) {
    PyObject *error = PyErr_GetRaisedException();
    if (!error) return @"Python 调用失败";
    PyObject *text = PyObject_Str(error);
    const char *utf8 = text ? PyUnicode_AsUTF8(text) : NULL;
    NSString *message = utf8 ? [NSString stringWithUTF8String:utf8] : @"无法读取 Python 异常";
    Py_XDECREF(text);
    Py_DECREF(error);
    PyErr_Clear();
    return message;
}

@implementation PythonEngine {
    dispatch_queue_t _queue;
    BOOL _busy;
    BOOL _initialized;
    NSString *_initializationError;
}

+ (PythonEngine *)shared {
    static PythonEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [[PythonEngine alloc] init]; });
    return engine;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("app.pypocket.interpreter", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)initializeInterpreter:(NSError **)error {
    if (_initialized) return YES;
    if (_initializationError) {
        *error = EngineError(_initializationError);
        return NO;
    }
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *home = [resources stringByAppendingPathComponent:@"python"];
    NSString *stdlib = [home stringByAppendingPathComponent:@"lib/python3.15"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[stdlib stringByAppendingPathComponent:@"encodings/__init__.py"]]) {
        *error = EngineError(@"安装包缺少 Python 标准库，请使用完整构建流程重新打包。");
        return NO;
    }
    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        _initializationError = [NSString stringWithUTF8String:status.err_msg ?: "Python 预初始化失败"];
        *error = EngineError(_initializationError);
        return NO;
    }
    if (PyImport_AppendInittab("_pypocket_native", InitHost) == -1) {
        _initializationError = @"无法注册 Python 原生桥接模块";
        *error = EngineError(_initializationError);
        return NO;
    }
    NSString *certificates = [resources stringByAppendingPathComponent:@"cacert.pem"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:certificates]) {
        setenv("SSL_CERT_FILE", certificates.UTF8String, 1);
        setenv("REQUESTS_CA_BUNDLE", certificates.UTF8String, 1);
    }
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.install_signal_handlers = 0;
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    config.use_environment = 0;
    config.module_search_paths_set = 1;
    status = PyConfig_SetBytesString(&config, &config.home, home.UTF8String);
    if (!PyStatus_Exception(status)) {
        status = PyConfig_SetBytesString(&config, &config.executable, NSBundle.mainBundle.executablePath.UTF8String);
    }
    if (!PyStatus_Exception(status)) {
        for (NSString *path in @[stdlib, [stdlib stringByAppendingPathComponent:@"lib-dynload"],
                                  [resources stringByAppendingPathComponent:@"runtime"]]) {
            wchar_t *wide = Py_DecodeLocale(path.UTF8String, NULL);
            if (!wide) { status = PyStatus_Error("Python 路径编码失败"); break; }
            status = PyWideStringList_Append(&config.module_search_paths, wide);
            PyMem_RawFree(wide);
            if (PyStatus_Exception(status)) break;
        }
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    if (PyStatus_Exception(status)) {
        _initializationError = [NSString stringWithUTF8String:status.err_msg ?: "Python 初始化失败"];
        PyConfig_Clear(&config);
        *error = EngineError(_initializationError);
        return NO;
    }
    PyConfig_Clear(&config);
    // CPython 初始化线程持有 GIL；释放后各次串行调用再显式获取。
    PyEval_SaveThread();
    _initialized = YES;
    return YES;
}

- (void)invokeModule:(NSString *)module function:(NSString *)function json:(NSString *)json completion:(PythonCompletion)completion {
    @synchronized (self) {
        if (_busy) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, EngineError(@"已有任务运行，请先停止并等待退出。")); });
            return;
        }
        _busy = YES;
        atomic_store(&cancellationRequested, false);
    }
    dispatch_async(_queue, ^{
        @autoreleasepool {
            NSError *error = nil;
            NSString *result = nil;
            if ([self initializeInterpreter:&error]) {
                PyGILState_STATE state = PyGILState_Ensure();
                outputHandler = [self.logHandler copy];
                PyObject *loaded = PyImport_ImportModule(module.UTF8String);
                PyObject *callable = loaded ? PyObject_GetAttrString(loaded, function.UTF8String) : NULL;
                PyObject *argument = callable ? PyUnicode_FromString(json.UTF8String) : NULL;
                PyObject *value = argument ? PyObject_CallOneArg(callable, argument) : NULL;
                if (value && PyUnicode_Check(value)) {
                    const char *text = PyUnicode_AsUTF8(value);
                    if (text) result = [NSString stringWithUTF8String:text];
                }
                if (!result) error = EngineError(TakePythonError());
                Py_XDECREF(value);
                Py_XDECREF(argument);
                Py_XDECREF(callable);
                Py_XDECREF(loaded);
                outputHandler = nil;
                PyGILState_Release(state);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized (self) { self->_busy = NO; }
                completion(result, error);
            });
        }
    });
}

- (void)runJSON:(NSString *)json completion:(PythonCompletion)completion {
    [self invokeModule:@"pypocket_host" function:@"execute_json" json:json completion:completion];
}

- (void)importJSON:(NSString *)json completion:(PythonCompletion)completion {
    [self invokeModule:@"project_io" function:@"import_json" json:json completion:completion];
}

- (void)requestStop {
    // 不在 UI 线程等待 GIL，避免 CPU 密集脚本阻塞停止按钮。
    atomic_store(&cancellationRequested, true);
}
@end
