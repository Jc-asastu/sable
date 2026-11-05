export function createTickQueue(runTick) {
  let queue = Promise.resolve();
  return (orders) => {
    const run = queue.then(() => runTick(orders));
    queue = run.catch(() => {});
    return run;
  };
}
