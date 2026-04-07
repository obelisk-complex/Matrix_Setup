version: 1

formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
  file:
    class: logging.handlers.TimedRotatingFileHandler
    formatter: precise
    filename: {{LOG_FILE_PATH}}
    when: midnight
    backupCount: 7
    encoding: utf8

  console:
    class: logging.StreamHandler
    formatter: precise
    stream: 'ext://sys.stdout'

loggers:
  synapse.storage.SQL:
    level: WARNING

root:
  level: INFO
  handlers: [file, console]

disable_existing_loggers: false
