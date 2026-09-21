//! Prints share state once a second. Run it, start a screen share, watch it flip.
#[path = "../watchdog.rs"]
mod watchdog;

#[tokio::main]
async fn main() {
    let mut rx = watchdog::spawn();
    println!("watching the PipeWire graph, ctrl-c to stop");
    for _ in 0..20 {
        let state = rx.borrow_and_update().clone();
        println!(
            "  sharing={} scope={:?} consumers={:?}",
            state.sharing, state.scope, state.consumers
        );
        tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
    }
}
