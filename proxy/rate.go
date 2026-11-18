package main

import (
	"sync"
	"time"
)

// tokenLimiter 는 임시 토큰마다 요청 수를 제한하는 토큰 버킷이다(공개 주소로 열리므로 토큰 하나가
// 공급사·backend 를 몰아 부르지 못하게). 버킷은 burst 개로 시작해 초당 perMinute/60 개씩 찬다.
// perMinute 이 0 이하면 제한하지 않는다. 오래 쓰지 않은 버킷은 가끔 치운다(메모리가 토큰 수만큼 늘지 않게).
type tokenLimiter struct {
	mu        sync.Mutex
	perSecond float64
	burst     float64
	now       func() time.Time
	buckets   map[string]*bucket
	lastSweep time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

// idleAfter 가 지나도록 쓰지 않은 버킷은 가득 찬 것과 같으므로 지워도 된다.
const idleAfter = 10 * time.Minute

func newTokenLimiter(perMinute, burst int, now func() time.Time) *tokenLimiter {
	if now == nil {
		now = time.Now
	}
	if burst < 1 {
		burst = 1
	}
	return &tokenLimiter{
		perSecond: float64(perMinute) / 60,
		burst:     float64(burst),
		now:       now,
		buckets:   map[string]*bucket{},
	}
}

// allow 는 key(임시 토큰)의 요청 하나를 받아도 되는지. 받으면 버킷에서 하나를 뺀다.
func (l *tokenLimiter) allow(key string) bool {
	if l == nil || l.perSecond <= 0 {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if now.Sub(l.lastSweep) > idleAfter {
		for k, b := range l.buckets {
			if now.Sub(b.last) > idleAfter {
				delete(l.buckets, k)
			}
		}
		l.lastSweep = now
	}
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	}
	b.tokens += now.Sub(b.last).Seconds() * l.perSecond
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}
