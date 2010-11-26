{application, amqp_client,
 [{description, "RabbitMQ AMQP Client"},
  {vsn, "0.0.0"},
  {modules, [
             amqp_channel,
             amqp_channels_manager,
             amqp_connection,
             amqp_direct_connection,
             amqp_main_reader,
             amqp_network_connection,
             amqp_rpc_client,
             amqp_rpc_server
  ]},
  {registered, []},
  {env, []},
  {mod, {amqp_client, []}},
  {applications, [kernel, stdlib]}]}.