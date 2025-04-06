local config = require('devcontainers.config')
return require('devcontainers.log.logger').make_registry('devcontainers', config.log)
