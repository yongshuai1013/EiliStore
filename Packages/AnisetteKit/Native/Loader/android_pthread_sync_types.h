#ifndef ANDROID_PTHREAD_SYNC_TYPES_H
#define ANDROID_PTHREAD_SYNC_TYPES_H

#include <cstdint>
#include <mutex>
#include <unordered_map>

// Ownership is guest-state only; this bounded model supports one guest thread.
struct AndroidGuestMutexState {
    bool held = false;
    bool destroyed = false;
};
struct AndroidGuestRWLockState {
    uint32_t readers = 0;
    bool writer = false;
    bool destroyed = false;
};
struct AndroidGuestSyncState {
    std::mutex mutex;
    std::unordered_map<uint64_t, AndroidGuestMutexState> mutexes;
    std::unordered_map<uint64_t, AndroidGuestRWLockState> rwlocks;
};

#endif
