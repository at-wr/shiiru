import UIKit

final class MainTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let stickers = UINavigationController(rootViewController: PacksViewController())
        stickers.navigationBar.prefersLargeTitles = true
        stickers.tabBarItem = UITabBarItem(
            title: "Stickers",
            image: UIImage(systemName: "square.grid.2x2"),
            selectedImage: UIImage(systemName: "square.grid.2x2.fill")
        )

        let settings = UINavigationController(rootViewController: SettingsViewController())
        settings.navigationBar.prefersLargeTitles = true
        settings.tabBarItem = UITabBarItem(
            title: "Settings",
            image: UIImage(systemName: "gearshape"),
            selectedImage: UIImage(systemName: "gearshape.fill")
        )

        viewControllers = [stickers, settings]
        tabBar.tintColor = Theme.accent

        switch PreviewMode.isActive ? PreviewMode.uiPreviewTab : nil {
        case "settings":
            selectedIndex = 1
        case "about":
            selectedIndex = 1
            settings.pushViewController(AboutViewController(), animated: false)
        default:
            break
        }
    }
}
