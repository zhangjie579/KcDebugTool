#include <assert.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#include "queue.h"


struct DSQueue {
    /* An array of elements in the queue. */
    void **buf;

    /* The position of the first element in the queue. 在队列中第1个元素的位置 */
    uint32_t pos;

    /* The number of items currently in the queue.
     * When `length` = 0, ds_queue_get will block.
     * When `length` = `capacity`, ds_queue_put will block. */
    uint32_t length;

    /* The total number of allowable items in the queue */
    uint32_t capacity;

    /* When true, the queue has been closed. A run-time error will occur
     * if a value is sent to a closed queue. */
    bool closed;

    /* Guards the modification of `length` (a condition variable) and `pos`. */
    pthread_mutex_t mutate;

    /* A condition variable that is pinged whenever `length` has changed or
     * when the queue has been closed. */
    pthread_cond_t cond_length;
};

/// 创建
struct DSQueue *ds_queue_create(uint32_t buffer_capacity) {
    struct DSQueue *queue;
    int errno;

    assert(buffer_capacity > 0);

    queue = malloc(sizeof(*queue));
    assert(queue);

    queue->pos = 0;
    queue->length = 0;
    queue->capacity = buffer_capacity;
    queue->closed = false;

    // buffer
    queue->buf = malloc(buffer_capacity * sizeof(*queue->buf));
    assert(queue->buf);

    if (0 != (errno = pthread_mutex_init(&queue->mutate, NULL))) {
        fprintf(stderr, "Could not create mutex. Errno: %d\n", errno);
        exit(1);
    }
    if (0 != (errno = pthread_cond_init(&queue->cond_length, NULL))) {
        fprintf(stderr, "Could not create cond var. Errno: %d\n", errno);
        exit(1);
    }

    return queue;
}

/// 释放
void ds_queue_free(struct DSQueue *queue) {
    if (!queue) {
        return;
    }
    int errno;

    if (0 != (errno = pthread_mutex_destroy(&queue->mutate))) {
        fprintf(stderr, "Could not destroy mutex. Errno: %d\n", errno);
        exit(1);
    }
    if (0 != (errno = pthread_cond_destroy(&queue->cond_length))) {
        fprintf(stderr, "Could not destroy cond var. Errno: %d\n", errno);
        exit(1);
    }
    free(queue->buf);
    free(queue);
}

int ds_queue_length(struct DSQueue *queue) {
    if (!queue) {
        return 0;
    }
    int len;
    pthread_mutex_lock(&queue->mutate);
    len = queue->length;
    pthread_mutex_unlock(&queue->mutate);
    return len;
}

int ds_queue_capacity(struct DSQueue *queue) {
    if (!queue) {
        return 0;
    }
    return queue->capacity;
}

/// 关闭close
void ds_queue_close(struct DSQueue *queue) {
    if (!queue) {
        return;
    }
    pthread_mutex_lock(&queue->mutate);
    queue->closed = true;
    pthread_cond_broadcast(&queue->cond_length); // 触发条件
    pthread_mutex_unlock(&queue->mutate);
}

void ds_queue_put(struct DSQueue *queue, void *item) {
    if (!queue) {
        return;
    }
    pthread_mutex_lock(&queue->mutate);
    assert(!queue->closed);

    // 1.不支持扩容, 满了的话, wait; 这里用while而不是if, 因为多线程情况下, 可能上一秒满足, 下一秒就不满足了
    while (queue->length == queue->capacity)
        pthread_cond_wait(&queue->cond_length, &queue->mutate);

    assert(!queue->closed);
    assert(queue->length < queue->capacity);

    // 2.add, pos为第1个元素的位置(第1个元素不一定是第0位)
    queue->buf[(queue->pos + queue->length) % queue->capacity] = item;
    queue->length++;
    pthread_cond_broadcast(&queue->cond_length);

    pthread_mutex_unlock(&queue->mutate);
}

void *ds_queue_get(struct DSQueue *queue) {
    if (!queue) {
        return NULL;
    }
    void *item;

    pthread_mutex_lock(&queue->mutate);

    // 1.容错
    while (queue->length == 0) {
        /* This is a bit tricky. It is possible that the queue has been closed
         * *and* has become empty while `pthread_cond_wait` is blocking.
         * Therefore, it is necessary to always check if the queue has been
         * closed when the queue is empty, otherwise we will deadlock. */
        if (queue->closed) {
            pthread_mutex_unlock(&queue->mutate);
            return NULL;
        }
        pthread_cond_wait(&queue->cond_length, &queue->mutate);
    }

    assert(queue->length <= queue->capacity);
    assert(queue->length > 0);

    // 2.get
    item = queue->buf[queue->pos];
    queue->buf[queue->pos] = NULL;
    // 获取后, pos后移1位
    queue->pos = (queue->pos + 1) % queue->capacity;

    queue->length--;
    pthread_cond_broadcast(&queue->cond_length); // 唤醒

    pthread_mutex_unlock(&queue->mutate);

    return item;
}

/// 添加item, 如果满了pop first
void* ds_queue_put_pop_first_item_if_need(struct DSQueue *queue, void *item) {
    if (!queue) {
        return NULL;
    }
    void *pop_item = NULL;
    
    pthread_mutex_lock(&queue->mutate);
    assert(!queue->closed);
    
    // pop the first item if queue is full 如果queue满了, pop第1个
    if (queue->length == queue->capacity) {
        assert(queue->length > 0);
        
        pop_item = queue->buf[queue->pos];
        queue->buf[queue->pos] = NULL;
        queue->pos = (queue->pos + 1) % queue->capacity;
        queue->length--;
    }
    
    assert(queue->length < queue->capacity);
    
    queue->buf[(queue->pos + queue->length) % queue->capacity] = item;
    queue->length++;
    pthread_cond_broadcast(&queue->cond_length);
    
    pthread_mutex_unlock(&queue->mutate);
    return pop_item;
}

/// 获取
void* ds_queue_try_get(struct DSQueue *queue) {
    if (!queue) {
        return NULL;
    }
    void *item = NULL;
    
    pthread_mutex_lock(&queue->mutate);
    
    if (queue->length == 0) {
        pthread_mutex_unlock(&queue->mutate);
        return NULL;
    }
    
    assert(queue->length <= queue->capacity);
    assert(queue->length > 0);
    
    item = queue->buf[queue->pos];
    queue->buf[queue->pos] = NULL;
    queue->pos = (queue->pos + 1) % queue->capacity;
    
    queue->length--;
    pthread_cond_broadcast(&queue->cond_length);
    
    pthread_mutex_unlock(&queue->mutate);
    
    return item;
}
