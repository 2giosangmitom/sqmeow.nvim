//! Typed read handles share the retained frame's buffers, not its values.
//! Downcast once when publishing/appending; hot cell reads use ordinary slices.

use polars::chunked_array::object::ObjectArray;
use polars::prelude::{DataFrame, ObjectChunked};

use crate::value::{Cell, RetainedCell};

#[derive(Debug, Clone)]
pub(super) struct RetainedFrame {
    pub frame: DataFrame,
    columns: Vec<CellColumn>,
}

impl RetainedFrame {
    pub fn new(frame: DataFrame) -> Self {
        let mut held = Self {
            frame,
            columns: Vec::new(),
        };
        held.refresh();
        held
    }

    fn refresh(&mut self) {
        self.columns = self
            .frame
            .columns()
            .iter()
            .map(|column| {
                let values = column
                    .as_materialized_series()
                    .as_any()
                    .downcast_ref::<ObjectChunked<RetainedCell>>()
                    .expect("retained cell column");
                let chunks: Vec<_> = values.downcast_iter().cloned().collect();
                let mut end = 0;
                let ends = chunks
                    .iter()
                    .map(|chunk| {
                        end += chunk.values_iter().len();
                        end
                    })
                    .collect();
                CellColumn { chunks, ends }
            })
            .collect();
    }

    pub fn append(&mut self, appended: Self) {
        self.frame
            .vstack_mut_owned(appended.frame)
            .expect("same retained schema");
        for (held, appended) in self.columns.iter_mut().zip(appended.columns) {
            let mut end = held.ends.last().copied().unwrap_or(0);
            for chunk in appended.chunks {
                end += chunk.values_iter().len();
                held.chunks.push(chunk);
                held.ends.push(end);
            }
        }
    }

    #[inline]
    pub fn column(&self, index: usize) -> Option<&CellColumn> {
        self.columns.get(index)
    }
}

#[derive(Debug, Clone)]
pub(crate) struct CellColumn {
    chunks: Vec<ObjectArray<RetainedCell>>,
    ends: Vec<usize>,
}

impl CellColumn {
    #[inline]
    pub fn get(&self, row: usize) -> Option<&Cell> {
        // Ordinary retained results have one chunk; appends keep older chunks
        // shared and use a prefix index for random reads across chunk boundaries.
        if let Some(value) = self.chunks.first()?.values_iter().as_slice().get(row) {
            return Some(&value.0);
        }
        self.get_appended(row)
    }

    fn get_appended(&self, row: usize) -> Option<&Cell> {
        let chunk = self.ends.partition_point(|&end| end <= row);
        let offset = if chunk == 0 { 0 } else { self.ends[chunk - 1] };
        self.chunks
            .get(chunk)?
            .values_iter()
            .as_slice()
            .get(row - offset)
            .map(|value| &value.0)
    }

    pub(super) fn iter(&self) -> Cells<'_> {
        Cells {
            chunks: self.chunks.iter(),
            current: [].iter(),
            remaining: self.ends.last().copied().unwrap_or(0),
        }
    }
}

pub(super) struct Cells<'a> {
    chunks: std::slice::Iter<'a, ObjectArray<RetainedCell>>,
    current: std::slice::Iter<'a, RetainedCell>,
    remaining: usize,
}

impl<'a> Cells<'a> {
    pub(super) fn new(column: Option<&'a CellColumn>) -> Self {
        column.map_or(
            Self {
                chunks: [].iter(),
                current: [].iter(),
                remaining: 0,
            },
            CellColumn::iter,
        )
    }
}

impl<'a> Iterator for Cells<'a> {
    type Item = &'a Cell;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            if let Some(value) = self.current.next() {
                self.remaining -= 1;
                return Some(&value.0);
            }
            self.current = self.chunks.next()?.values_iter();
        }
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.remaining, Some(self.remaining))
    }
}

impl ExactSizeIterator for Cells<'_> {}
