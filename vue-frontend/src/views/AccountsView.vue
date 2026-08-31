<script setup>
/* Purpose 3: list the customer's accounts with open/closed status. */
import { onMounted, ref } from 'vue'
import { RouterLink } from 'vue-router'

import { useSession } from '../stores/session'

const session = useSession()
const error = ref(null)

onMounted(async () => {
  try {
    await session.loadAccounts()
  } catch (err) {
    error.value = err.message
  }
})
</script>

<template>
  <h1>Your accounts</h1>
  <p v-if="error" class="error">{{ error }}</p>

  <p v-else-if="!session.accounts.length">No accounts.</p>

  <table v-else>
    <thead>
      <tr><th>Account</th><th>Label</th><th>Service</th><th>Status</th></tr>
    </thead>
    <tbody>
      <tr v-for="account in session.accounts" :key="account.accountId">
        <td>
          <RouterLink :to="{ name: 'account', params: { accountId: account.accountId } }">
            {{ account.accountId }}
          </RouterLink>
        </td>
        <td>{{ account.label }}</td>
        <td>{{ account.serviceType }}</td>
        <td><span class="status" :data-status="account.status">{{ account.status }}</span></td>
      </tr>
    </tbody>
  </table>
</template>
