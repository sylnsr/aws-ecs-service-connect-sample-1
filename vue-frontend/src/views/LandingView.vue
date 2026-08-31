<script setup>
/* Purposes 1 and 2: unauthenticated landing content, then sign in. */
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'

import { api } from '../api'
import { useSession } from '../stores/session'

const session = useSession()
const router = useRouter()

const landing = ref(null)
const landingError = ref(null)

// Pre-filled so the demo is one click. The backend accepts any customerId and
// any password -- it is a mock issuer, see python-backend/README.md.
const customerId = ref('cust-lorem-0001')
// The x-account-count header. This is the interesting control on the page:
// purpose 2 is "authorize for the number of accounts in the header", so the
// value chosen here decides how long the account list is.
const accountCount = ref(3)

onMounted(async () => {
  try {
    landing.value = await api.landing()
  } catch (err) {
    landingError.value = err.message
  }
})

async function submit() {
  try {
    await session.signIn(customerId.value, accountCount.value)
    router.push({ name: 'accounts' })
  } catch {
    // Already surfaced via session.error.
  }
}
</script>

<template>
  <section v-if="landingError" class="error">Could not load landing content: {{ landingError }}</section>

  <section v-else-if="landing">
    <h1>{{ landing.title }}</h1>
    <p class="hero">{{ landing.hero }}</p>

    <div v-for="section in landing.sections" :key="section.heading">
      <h2>{{ section.heading }}</h2>
      <p>{{ section.body }}</p>
    </div>

    <!--
      These hrefs are the vanity URLs from edge/kvs/routing.yaml (/pay, /bill,
      /join). CloudFront rewrites them onto the real API paths at the edge, so
      they are deliberately NOT router links.
    -->
    <ul class="links">
      <li v-for="link in landing.links" :key="link.href">
        <a :href="link.href">{{ link.label }}</a>
      </li>
    </ul>
  </section>

  <section class="card">
    <h2>Sign in</h2>
    <form @submit.prevent="submit">
      <label>
        Customer ID
        <input v-model="customerId" required />
      </label>
      <label>
        Number of accounts
        <input v-model.number="accountCount" type="number" min="1" max="10" required />
        <small>Sent as the <code>x-account-count</code> header.</small>
      </label>
      <button type="submit" :disabled="session.busy">
        {{ session.busy ? 'Signing in…' : 'Sign in' }}
      </button>
    </form>
    <p v-if="session.error" class="error">{{ session.error }}</p>
  </section>
</template>
