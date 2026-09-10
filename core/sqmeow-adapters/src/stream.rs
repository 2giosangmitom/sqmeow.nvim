//! Draining a query's rows, the same way for every database.
//!
//! The cancel check, the row cap and the split between "rows came back" and "rows were changed"
//! are identical whichever driver produced the stream, and they are the parts that must be right.
//! Keeping one copy means a fix reaches every adapter.

use futures_util::{Stream, StreamExt};
use sqlx::Either;
use sqmeow_db::{Cell, Error, Result, ResultSet};
use tokio_util::sync::CancellationToken;

/// Read a query's output into a result set.
///
/// `affected` reads a row count off the driver's own query-result type, and `decode` turns one of
/// its rows into cells. Everything else is shared.
pub(crate) async fn drain<S, Q, R>(
    mut stream: S,
    result: &mut ResultSet,
    max_rows: usize,
    cancel: &CancellationToken,
    affected: impl Fn(&Q) -> u64,
    decode: impl Fn(&R) -> Vec<Cell>,
) -> Result<()>
where
    S: Stream<Item = std::result::Result<Either<Q, R>, sqlx::Error>> + Unpin,
{
    loop {
        tokio::select! {
            // Cancellation wins a tie, so a held cancel is honoured even while rows arrive faster
            // than the loop can drain them.
            biased;

            () = cancel.cancelled() => return Err(Error::Cancelled),

            item = stream.next() => match item {
                None => return Ok(()),
                Some(Err(error)) => return Err(Error::driver(error)),
                Some(Ok(Either::Left(outcome))) => result.set_affected(affected(&outcome)),
                Some(Ok(Either::Right(row))) => {
                    if result.row_count() >= max_rows {
                        // Stopping here drops the stream, which tells the server to stop sending.
                        result.mark_truncated();
                        return Ok(());
                    }
                    result.push_row(decode(&row));
                }
            },
        }
    }
}
