import UIKit

final class CountryPickerViewController: UITableViewController, UISearchResultsUpdating {

    var onSelect: ((Country) -> Void)?

    private let allCountries = CountryCodes.all
    private var filtered: [Country]

    init() {
        filtered = allCountries
        super.init(style: .insetGrouped)
        title = "Country"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.preferSoftTopEdge()

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        filtered = query.isEmpty
            ? allCountries
            : allCountries.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.dialCode.hasPrefix(query)
            }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filtered.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let country = filtered[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "cell")
        cell.textLabel?.text = "\(country.flag)  \(country.name)"
        cell.detailTextLabel?.text = "+\(country.dialCode)"
        cell.detailTextLabel?.textColor = .secondaryLabel
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        Haptics.tap()
        onSelect?(filtered[indexPath.row])
        navigationController?.popViewController(animated: true)
    }
}
