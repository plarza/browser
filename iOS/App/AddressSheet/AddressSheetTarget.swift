/// What the address sheet is for.
enum AddressSheetTarget: Equatable {
    /// The tab showing: its address, selected to type over.
    case current
    /// A tab that doesn't exist until there is somewhere to go.
    case newTab
}
