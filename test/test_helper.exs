# geex ships no grammar or theme (ADR-0040): the fixture ones are installed into the test data
# directory (the app's `data_dir` under test), afresh each run, as a user would have them.
data_dir = Application.fetch_env!(:geex, :data_dir)
File.rm_rf!(data_dir)
Geex.Fixtures.install(data_dir)
Geex.Installed.refresh()

# Both are this run's own (config/config.exs names them for its OS process): gone when it ends.
ExUnit.after_suite(fn _ ->
  File.rm_rf(data_dir)
  File.rm(Application.fetch_env!(:geex, :settings_path))
end)

# A message a test waits for (`assert_receive`) gets 1 s, not ExUnit's 100 ms: under the full
# suite's load a watcher's restart or a background read can take longer, and the default made
# those tests flaky. A test that passes is no slower.
ExUnit.start(assert_receive_timeout: 1_000)
