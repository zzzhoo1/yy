<template>
  <v-icon
    :icon="icon"
    :size="size"
    :color="color"
    :start="start"
    :end="end"
    :class="styles.icon"
  />
</template>

<script setup lang="ts">
import styles from './styles.module.css'

withDefaults(
  defineProps<{
    icon: string
    size?: string | number
    color?: string
    start?: boolean
    end?: boolean
  }>(),
  {
    size: 'medium',
    color: '',
    start: false,
    end: false,
  }
)
</script>
