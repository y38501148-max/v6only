#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include "_cgo_export.h"
static JavaVM *vm;
static jobject service;
static jmethodID protect;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
void core_failed(long long generation, char *message) {
 JNIEnv *env; int detach=0;
 if ((*vm)->GetEnv(vm,(void**)&env,JNI_VERSION_1_6)!=JNI_OK) {if ((*vm)->AttachCurrentThread(vm,&env,NULL)!=JNI_OK) return;detach=1;}
 pthread_mutex_lock(&lock);
 if(service){
  jclass cls=(*env)->GetObjectClass(env,service);
  jmethodID method=(*env)->GetMethodID(env,cls,"onCoreFailure","(JLjava/lang/String;)V");
  jstring text=(*env)->NewStringUTF(env,message);
  if(method)(*env)->CallVoidMethod(env,service,method,(jlong)generation,text);
  (*env)->DeleteLocalRef(env,text);(*env)->DeleteLocalRef(env,cls);
  if((*env)->ExceptionCheck(env))(*env)->ExceptionClear(env);
 }
 pthread_mutex_unlock(&lock);
 if(detach)(*vm)->DetachCurrentThread(vm);
}
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *v, void *unused) { vm=v; return JNI_VERSION_1_6; }
int protect_fd(int fd) {
 JNIEnv *env; int detach=0;
 if ((*vm)->GetEnv(vm,(void**)&env,JNI_VERSION_1_6)!=JNI_OK) {if ((*vm)->AttachCurrentThread(vm,&env,NULL)!=JNI_OK) return 0;detach=1;}
 pthread_mutex_lock(&lock);
 jboolean ok=service?(*env)->CallBooleanMethod(env,service,protect,(jint)fd):JNI_FALSE;
 if ((*env)->ExceptionCheck(env)) {(*env)->ExceptionClear(env);ok=JNI_FALSE;}
 pthread_mutex_unlock(&lock);
 if(detach)(*vm)->DetachCurrentThread(vm);
 return ok;
}
static void release_service(JNIEnv *env){pthread_mutex_lock(&lock);if(service)(*env)->DeleteGlobalRef(env,service);service=NULL;pthread_mutex_unlock(&lock);}
JNIEXPORT jstring JNICALL Java_edu_buaa_v6only_CoreNative_start(JNIEnv *env,jclass cls,jint fd,jstring cfg,jobject owner){
 pthread_mutex_lock(&lock);service=(*env)->NewGlobalRef(env,owner);jclass c=(*env)->GetObjectClass(env,owner);protect=(*env)->GetMethodID(env,c,"protectCoreSocket","(I)Z");(*env)->DeleteLocalRef(env,c);pthread_mutex_unlock(&lock);
 const char *config=(*env)->GetStringUTFChars(env,cfg,NULL);char *error=startCore(fd,(char*)config);(*env)->ReleaseStringUTFChars(env,cfg,config);jstring result=(*env)->NewStringUTF(env,error);if(error[0])release_service(env);free(error);return result;
}
JNIEXPORT void JNICALL Java_edu_buaa_v6only_CoreNative_stop(JNIEnv *env,jclass cls){stopCore();release_service(env);}
JNIEXPORT jstring JNICALL Java_edu_buaa_v6only_CoreNative_flows(JNIEnv *env,jclass cls){char *value=coreFlows();jstring result=(*env)->NewStringUTF(env,value);free(value);return result;}
JNIEXPORT jstring JNICALL Java_edu_buaa_v6only_CoreNative_stats(JNIEnv *env,jclass cls,jstring path,jlong from,jlong to){const char *p=(*env)->GetStringUTFChars(env,path,NULL);char *value=coreStats((char*)p,from,to);(*env)->ReleaseStringUTFChars(env,path,p);jstring result=(*env)->NewStringUTF(env,value);free(value);return result;}
