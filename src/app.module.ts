import { Module } from '@nestjs/common';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { RestaurantsModule } from './resources/restaurants/restaurants.module';
import { SettingsModule } from './resources/settings/settings.module';
import { MenusModule } from './resources/menus/menus.module';
import { CategoriesModule } from './resources/categories/categories.module';
import { ProductsModule } from './resources/products/products.module';
import { PlansModule } from './resources/plans/plans.module';
import { TemplatesModule } from './resources/templates/templates.module';
import { AuthModule } from './resources/auth/auth.module';
import { DatabaseModule } from './config/database/database.module';
import { FirebaseModule } from './config/firebase/firebase.module';
import { CommonModule } from './common/common.module';
import { BannersModule } from './resources/banners/banners.module';
import { BranchesModule } from './resources/branches/branches.module';

@Module({
  imports: [
    RestaurantsModule,
    SettingsModule,
    MenusModule,
    CategoriesModule,
    ProductsModule,
    PlansModule,
    TemplatesModule,
    AuthModule,
    DatabaseModule,
    FirebaseModule,
    CommonModule,
    BannersModule,
    BranchesModule,
  ],
  controllers: [AppController],
  providers: [AppService],
})
export class AppModule {}
