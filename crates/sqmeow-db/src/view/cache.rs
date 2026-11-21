//! A bounded cache of full-scope typed projections, never of original cells.
//! The byte budget covers estimated typed buffers, not total process RSS.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};

use polars::prelude::DataFrame;

// Shared across retained results, so history size cannot multiply the budget.
static BUDGET: Budget = Budget {
    used: AtomicUsize::new(0),
    limit: 32 * 1024 * 1024,
};

struct Budget {
    used: AtomicUsize,
    limit: usize,
}

impl Budget {
    fn reserve(&'static self, bytes: usize) -> Option<Reservation> {
        self.used
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
                used.checked_add(bytes).filter(|&total| total <= self.limit)
            })
            .ok()
            .map(|_| Reservation {
                budget: self,
                bytes,
            })
    }
}

struct Reservation {
    budget: &'static Budget,
    bytes: usize,
}

impl Drop for Reservation {
    fn drop(&mut self) {
        self.budget.used.fetch_sub(self.bytes, Ordering::Relaxed);
    }
}

struct CachedFrame {
    frame: DataFrame,
    _reservation: Reservation,
}

/// Clones share both buffers and their reservation. Unused caches stay unused.
#[derive(Clone, Default)]
pub(crate) struct FrameCache {
    frame: OnceLock<Result<Option<Arc<CachedFrame>>, String>>,
}

impl std::fmt::Debug for FrameCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FrameCache")
            .field("initialized", &self.frame.get().is_some())
            .finish()
    }
}

impl FrameCache {
    pub fn clear(&mut self) {
        self.frame.take();
    }

    pub fn get(&self) -> Option<&DataFrame> {
        self.frame
            .get()?
            .as_ref()
            .ok()?
            .as_ref()
            .map(|held| &held.frame)
    }

    pub fn get_or_build(
        &self,
        build: impl FnOnce() -> Result<DataFrame, String>,
    ) -> Result<DataFrame, String> {
        self.with_budget(&BUDGET, build)
    }

    fn with_budget(
        &self,
        budget: &'static Budget,
        build: impl FnOnce() -> Result<DataFrame, String>,
    ) -> Result<DataFrame, String> {
        let mut build = Some(build);
        let mut uncached = None;
        let cached = self.frame.get_or_init(|| {
            let frame = build.take().expect("initializer runs once")()?;
            match budget.reserve(frame.estimated_size()) {
                Some(reservation) => Ok(Some(Arc::new(CachedFrame {
                    frame,
                    _reservation: reservation,
                }))),
                None => {
                    uncached = Some(frame);
                    Ok(None)
                }
            }
        });
        match cached {
            Ok(Some(held)) => Ok(held.frame.clone()),
            Ok(None) => match uncached {
                Some(frame) => Ok(frame),
                None => build.take().expect("uncached build not yet called")(),
            },
            Err(error) => Err(error.clone()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use polars::prelude::Column;

    #[test]
    fn concurrent_requests_share_one_projection_and_return_budget_on_drop() {
        static LOCAL: Budget = Budget {
            used: AtomicUsize::new(0),
            limit: 64,
        };
        let builds = AtomicUsize::new(0);
        let cache = FrameCache::default();
        std::thread::scope(|scope| {
            for _ in 0..2 {
                scope.spawn(|| {
                    cache
                        .with_budget(&LOCAL, || {
                            builds.fetch_add(1, Ordering::Relaxed);
                            DataFrame::new(8, vec![Column::new("v".into(), vec![1_i64; 8])])
                                .map_err(|e| e.to_string())
                        })
                        .unwrap();
                });
            }
        });
        assert_eq!(builds.load(Ordering::Relaxed), 1);
        assert_eq!(LOCAL.used.load(Ordering::Relaxed), 64);
        drop(cache);
        assert_eq!(LOCAL.used.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn denied_cache_builds_once_and_reservations_follow_shared_ownership() {
        static LOCAL: Budget = Budget {
            used: AtomicUsize::new(0),
            limit: 64,
        };
        let build = || {
            DataFrame::new(8, vec![Column::new("v".into(), vec![1_i64; 8])])
                .map_err(|e| e.to_string())
        };
        let mut first = FrameCache::default();
        first.with_budget(&LOCAL, build).unwrap();
        assert_eq!(LOCAL.used.load(Ordering::Relaxed), 64);
        let shared = first.clone();
        let second = FrameCache::default();
        let mut calls = 0;
        second
            .with_budget(&LOCAL, || {
                calls += 1;
                build()
            })
            .unwrap();
        assert_eq!(calls, 1, "denial must not discard and rebuild a frame");
        assert!(second.get().is_none());
        first.clear();
        assert_eq!(LOCAL.used.load(Ordering::Relaxed), 64);
        drop(shared);
        assert_eq!(LOCAL.used.load(Ordering::Relaxed), 0);
    }
}
