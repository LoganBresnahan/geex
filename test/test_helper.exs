# A message a test waits for (`assert_receive`) gets 1 s, not ExUnit's 100 ms: under the full
# suite's load a watcher's restart or a background read can take longer, and the default made
# those tests flaky. A test that passes is no slower.
ExUnit.start(assert_receive_timeout: 1_000)
