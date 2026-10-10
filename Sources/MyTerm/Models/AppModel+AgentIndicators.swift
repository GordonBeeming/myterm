import MyTermUI

extension AppModel {
    var agentIndicatorAppearance: AgentIndicatorAppearance {
        // The store is not observable; its mutations invalidate views through the model's version.
        _ = stateVersion
        return AgentIndicatorAppearance(preferences: store.globalSettings)
    }
}
