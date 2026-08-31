<script setup>
/*
 * One account, four purposes:
 *   4 -- address (read only)
 *   7 -- payment history, debits and credits
 *   6 -- loyalty signup / loyalty ID
 *   8 -- closure request and its status
 *
 * They share a page because they share a subject. Splitting them into four
 * routes would mean four navigations to see one account.
 */
import { computed, onMounted, ref, watch } from 'vue'

import { ApiError, api } from '../api'

const props = defineProps({ accountId: { type: String, required: true } })

const address = ref(null)
const addressLines = computed(() => {
  const a = address.value?.address
  if (!a) return []
  return [a.line1, a.line2, a.city, a.region, a.postalCode, a.country].filter(Boolean)
})
const history = ref(null)
const loyalty = ref(null)
const closure = ref(null)
const error = ref(null)
const busy = ref(false)

// A 404 from loyalty or closure is not an error -- it is the "not enrolled" and
// "no request in flight" state. Anything else genuinely failed.
async function orNull(promise) {
  try {
    return await promise
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null
    throw err
  }
}

async function load() {
  error.value = null
  try {
    ;[address.value, history.value, loyalty.value, closure.value] = await Promise.all([
      api.address(props.accountId),
      api.paymentHistory(props.accountId),
      orNull(api.loyalty(props.accountId)),
      orNull(api.closureStatus(props.accountId)),
    ])
  } catch (err) {
    error.value = err.message
  }
}

onMounted(load)
// The route can change without the component remounting (account -> account).
watch(() => props.accountId, load)

async function join() {
  busy.value = true
  try {
    loyalty.value = await api.joinLoyalty(props.accountId)
  } catch (err) {
    error.value = err.message
  } finally {
    busy.value = false
  }
}

async function close() {
  busy.value = true
  try {
    closure.value = await api.requestClosure(props.accountId, 'Lorem ipsum relocation', '2026-09-30')
  } catch (err) {
    error.value = err.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <h1>{{ accountId }}</h1>
  <p v-if="error" class="error">{{ error }}</p>

  <section class="card" v-if="address">
    <h2>Address</h2>
    <!-- Read only. There is no write verb on this path; the backend does not
         route PUT/POST/PATCH/DELETE and the @stateful tests assert that. -->
    <p class="badge" v-if="address.readOnly">Read only</p>
    <address>
      <!-- line2 is legitimately null for some addresses, so index the key
           rather than the value and drop the empties first. -->
      <div v-for="(line, i) in addressLines" :key="i">{{ line }}</div>
    </address>
  </section>

  <section class="card" v-if="history">
    <h2>Payment history</h2>
    <table>
      <thead><tr><th>Date</th><th>Description</th><th>Type</th><th>Amount</th></tr></thead>
      <tbody>
        <tr v-for="entry in history.transactions" :key="entry.transactionId">
          <td>{{ entry.date }}</td>
          <td>{{ entry.description }}</td>
          <td><span class="status" :data-status="entry.type">{{ entry.type }}</span></td>
          <td>{{ history.currency }} {{ entry.amount.toFixed(2) }}</td>
        </tr>
      </tbody>
    </table>
  </section>

  <section class="card">
    <h2>Loyalty</h2>
    <p v-if="loyalty">
      Member <strong>{{ loyalty.loyaltyId }}</strong> — {{ loyalty.status }}
      <span v-if="loyalty.points != null">, {{ loyalty.points }} points</span>
    </p>
    <template v-else>
      <p>Not enrolled.</p>
      <button type="button" :disabled="busy" @click="join">Join loyalty programme</button>
    </template>
  </section>

  <section class="card">
    <h2>Account closure</h2>
    <p v-if="closure">
      Request <strong>{{ closure.closureRequestId }}</strong> is
      <span class="status" data-status="pending">{{ closure.status }}</span>,
      effective {{ closure.effectiveDate }}.
    </p>
    <template v-else>
      <p>No closure request.</p>
      <button type="button" :disabled="busy" @click="close">Request closure</button>
    </template>
  </section>
</template>
