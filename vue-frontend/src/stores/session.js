import { defineStore } from 'pinia'
import { ref } from 'vue'

import { api, storedToken } from '../api'

// Only genuinely shared state lives here: who is signed in, their account list,
// and which pool is serving us. Per-view data (one account's address, its
// payment history) is fetched by the view that renders it -- caching it here
// would mean inventing an invalidation rule for a demo that has none.
export const useSession = defineStore('session', () => {
  const signedIn = ref(Boolean(storedToken()))
  const customerId = ref('')
  const accounts = ref([])
  const pool = ref(null)
  const error = ref(null)
  const busy = ref(false)

  async function signIn(id, accountCount) {
    busy.value = true
    error.value = null
    try {
      await api.signIn(id, accountCount)
      customerId.value = id
      signedIn.value = true
      await loadAccounts()
    } catch (err) {
      error.value = err.message
      signedIn.value = false
      throw err
    } finally {
      busy.value = false
    }
  }

  function signOut() {
    api.signOut()
    signedIn.value = false
    accounts.value = []
    customerId.value = ''
  }

  async function loadAccounts() {
    accounts.value = (await api.accounts()).accounts
  }

  async function loadPool() {
    // Best effort. Not knowing which pool served us is cosmetic, and a failure
    // here must not stop the app rendering.
    try {
      pool.value = await api.whoami()
    } catch {
      pool.value = null
    }
  }

  return { signedIn, customerId, accounts, pool, error, busy, signIn, signOut, loadAccounts, loadPool }
})
