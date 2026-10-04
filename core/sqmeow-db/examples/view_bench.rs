//! `cargo run -p sqmeow-db --release --example view_bench -- 100000 10`
//! Process peak RSS is Linux-only; measure binary/build size separately for the core binary.

use std::hint::black_box;
use std::time::Instant;

use sqmeow_db::result::{Column, ResultSet};
use sqmeow_db::value::Cell;
use sqmeow_db::view::{self, Filter, Op, Sort};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let rows = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(100_000);
    let reps = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(10);
    let mut result = ResultSet::new(
        "benchmark",
        vec![Column::new("id", "INTEGER"), Column::new("label", "TEXT")],
    );
    for index in 0..rows {
        result.push_row(vec![
            Cell::Int(index as i64),
            if index % 17 == 0 {
                Cell::Null
            } else {
                Cell::Text(format!("group-{}", index % 100))
            },
        ]);
    }
    let filters = [Filter {
        column: Some(0),
        op: Op::Ge,
        value: (rows / 2).to_string(),
    }];
    let sort = [
        Sort {
            column: 1,
            descending: true,
        },
        Sort {
            column: 0,
            descending: false,
        },
    ];
    println!("engine,rows,reps,median_ms,peak_rss_kib");
    measure("polars", rows, reps, || {
        view::select_with(&result, &filters, &sort, None, None).expect("view should build")
    });
}

fn measure(name: &str, rows: usize, reps: usize, mut select: impl FnMut() -> Vec<usize>) {
    black_box(select());
    let mut times = Vec::with_capacity(reps);
    for _ in 0..reps {
        let start = Instant::now();
        black_box(select());
        times.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    times.sort_by(f64::total_cmp);
    let median = times.get(reps / 2).copied().unwrap_or_default();
    let peak = std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|status| {
            status
                .lines()
                .find(|line| line.starts_with("VmHWM:"))
                .and_then(|line| line.split_whitespace().nth(1))
                .and_then(|value| value.parse::<usize>().ok())
        });
    println!(
        "{name},{rows},{reps},{median:.3},{}",
        peak.map_or(String::new(), |value| value.to_string())
    );
}
