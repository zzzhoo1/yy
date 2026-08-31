import { createVuetify } from 'vuetify/lib/entry-bundler.mjs'
import { config } from '@vue/test-utils'

const vuetify = createVuetify()

config.global.plugins = [vuetify]
