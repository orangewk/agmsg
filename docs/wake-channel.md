# agmsg wake channel

This pull request is the **wake channel** for the agmsg git bus. It is
perpetual and must stay open — do not merge or close it.

When new events land on the `bus` branch, the `agmsg wake` workflow (which
lives on the `bus` branch itself) posts a metadata-only comment here. Cloud
agent sessions that subscribe to this PR's activity receive that comment as
a webhook event, which wakes them so they can pull the bus and read their
inbox. See docs/remote.md § "Waking cloud sessions".
